// SPDX-License-Identifier: MIT
#include <errno.h>
#include <poll.h>
#include <string.h>

#include "rs6-target.h"

int rs6_target_open(struct rs6_target *t, const char *ctl_name)
{
	snd_ctl_elem_info_t *info;
	unsigned int i, items;
	int err;

	memset(t, 0, sizeof(*t));
	err = snd_ctl_open(&t->ctl, ctl_name, SND_CTL_NONBLOCK);
	if (err < 0)
		return err;
	if ((err = snd_ctl_elem_id_malloc(&t->id)) < 0 ||
	    (err = snd_ctl_elem_value_malloc(&t->val)) < 0)
		goto fail;
	snd_ctl_elem_id_set_interface(t->id, SND_CTL_ELEM_IFACE_MIXER);
	snd_ctl_elem_id_set_name(t->id, RS6_TARGET_CTL_NAME);

	snd_ctl_elem_info_alloca(&info);
	snd_ctl_elem_info_set_id(info, t->id);
	err = snd_ctl_elem_info(t->ctl, info);
	if (err < 0)
		goto fail;
	if (snd_ctl_elem_info_get_type(info) != SND_CTL_ELEM_TYPE_ENUMERATED) {
		err = -EINVAL;
		goto fail;
	}
	t->numid = snd_ctl_elem_info_get_numid(info);
	snd_ctl_elem_id_set_numid(t->id, t->numid);
	snd_ctl_elem_value_set_id(t->val, t->id);

	/* by name: the list has no Auto, so its indices differ from the Output control's */
	items = snd_ctl_elem_info_get_items(info);
	for (i = 0; i < items; i++) {
		snd_ctl_elem_info_set_item(info, i);
		if (snd_ctl_elem_info(t->ctl, info) < 0)
			continue;
		if (!strcmp(snd_ctl_elem_info_get_item_name(info), RS6_TARGET_SPDIF_ITEM))
			break;
	}
	if (i == items) {
		err = -EINVAL;
		goto fail;
	}
	t->spdif_item = i;

	err = snd_ctl_subscribe_events(t->ctl, 1);
	if (err < 0)
		goto fail;
	return 0;

fail:
	rs6_target_close(t);
	return err;
}

void rs6_target_close(struct rs6_target *t)
{
	if (t->ctl)
		snd_ctl_close(t->ctl);
	snd_ctl_elem_id_free(t->id);
	snd_ctl_elem_value_free(t->val);
	memset(t, 0, sizeof(*t));
}

int rs6_target_is_spdif(struct rs6_target *t)
{
	int err = snd_ctl_elem_read(t->ctl, t->val);

	if (err < 0)
		return err;
	return snd_ctl_elem_value_get_enumerated(t->val, 0) == t->spdif_item;
}

int rs6_target_events(struct rs6_target *t)
{
	snd_ctl_event_t *ev;
	int hit = 0, err;

	snd_ctl_event_alloca(&ev);
	while ((err = snd_ctl_read(t->ctl, ev)) > 0) {
		if (snd_ctl_event_get_type(ev) != SND_CTL_EVENT_ELEM)
			continue;
		if (snd_ctl_event_elem_get_mask(ev) == SND_CTL_EVENT_MASK_REMOVE ||
		    snd_ctl_event_elem_get_numid(ev) == t->numid)
			hit = 1;
	}
	if (err < 0 && err != -EAGAIN)
		return err;
	return hit;
}

int rs6_target_fd(struct rs6_target *t)
{
	struct pollfd pfd;

	if (snd_ctl_poll_descriptors(t->ctl, &pfd, 1) != 1)
		return -EIO;
	return pfd.fd;
}

int rs6_target_card(struct rs6_target *t, int *index, char *id, size_t id_len)
{
	snd_ctl_card_info_t *info;
	int err;

	snd_ctl_card_info_alloca(&info);
	err = snd_ctl_card_info(t->ctl, info);
	if (err < 0)
		return err;
	*index = snd_ctl_card_info_get_card(info);
	snprintf(id, id_len, "%s", snd_ctl_card_info_get_id(info));
	return 0;
}
