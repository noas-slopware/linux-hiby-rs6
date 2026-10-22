// SPDX-License-Identifier: MIT
/*
 * ALSA control plugin "rs6_jack": two read-only jack controls derived from the hm100 codec's
 * "Output Target" (docs/spdif-dsd.md 9.4), so that PipeWire/PulseAudio UCM support can switch
 * between the RS6's two sinks the way it does for any jack:
 *
 *   "SPDIF Jack"  on while Output Target is Spdif (nothing plugged in, or Output forced to it)
 *   "DAC Jack"    on while it is anything else (3.5 mm, 4.4 mm, line out, balanced line out)
 *
 * UCM points JackCTL of both devices at "rs6_jack:<card>". The kernel stays as it is: its
 * controls are not jacks, and ACP only follows boolean CARD controls named "... Jack".
 * Every Output Target event becomes a value event on both controls.
 *
 * Config: ctl.name { type rs6_jack  card STR|INT (default "HiByRS6")  ctl STR (override) }
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <alsa/asoundlib.h>
#include <alsa/control_external.h>

#include "rs6-target.h"

static const char *const jack_names[] = { "SPDIF Jack", "DAC Jack" };
#define NUM_JACKS	2

struct rs6_jack {
	snd_ctl_ext_t ext;
	struct rs6_target tgt;
	int spdif;			/* cached Output Target == Spdif */
	unsigned int pending;		/* bit k: value event for jack k still to report */
	int subscribed;
};

static int refresh(struct rs6_jack *j)
{
	int v = rs6_target_is_spdif(&j->tgt);

	if (v < 0)
		return v;
	if (v != j->spdif) {
		j->spdif = v;
		return 1;
	}
	return 0;
}

static void jack_close(snd_ctl_ext_t *ext)
{
	struct rs6_jack *j = ext->private_data;

	rs6_target_close(&j->tgt);
	free(j);
}

static int jack_elem_count(snd_ctl_ext_t *ext)
{
	(void)ext;
	return NUM_JACKS;
}

static int jack_elem_list(snd_ctl_ext_t *ext, unsigned int offset, snd_ctl_elem_id_t *id)
{
	(void)ext;
	if (offset >= NUM_JACKS)
		return -EINVAL;
	snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_CARD);
	snd_ctl_elem_id_set_name(id, jack_names[offset]);
	return 0;
}

static snd_ctl_ext_key_t jack_find_elem(snd_ctl_ext_t *ext, const snd_ctl_elem_id_t *id)
{
	unsigned int k, numid = snd_ctl_elem_id_get_numid(id);

	(void)ext;
	if (numid > 0 && numid <= NUM_JACKS)
		return numid - 1;
	if (snd_ctl_elem_id_get_interface(id) != SND_CTL_ELEM_IFACE_CARD ||
	    snd_ctl_elem_id_get_index(id) != 0)
		return SND_CTL_EXT_KEY_NOT_FOUND;
	for (k = 0; k < NUM_JACKS; k++)
		if (!strcmp(snd_ctl_elem_id_get_name(id), jack_names[k]))
			return k;
	return SND_CTL_EXT_KEY_NOT_FOUND;
}

static int jack_get_attribute(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, int *type,
			      unsigned int *acc, unsigned int *count)
{
	(void)ext;
	if (key >= NUM_JACKS)
		return -EINVAL;
	*type = SND_CTL_ELEM_TYPE_BOOLEAN;
	*acc = SND_CTL_EXT_ACCESS_READ | SND_CTL_EXT_ACCESS_VOLATILE;
	*count = 1;
	return 0;
}

static int jack_get_integer_info(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, long *imin,
				 long *imax, long *istep)
{
	(void)ext;
	(void)key;
	*imin = 0;
	*imax = 1;
	*istep = 1;
	return 0;
}

static int jack_read_integer(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, long *value)
{
	struct rs6_jack *j = ext->private_data;
	int err = refresh(j);

	if (err < 0)
		return err;
	if (err > 0)
		j->pending = (1u << NUM_JACKS) - 1;	/* changed behind our back: tell everyone */
	*value = key == 0 ? j->spdif : !j->spdif;
	return 0;
}

static void jack_subscribe_events(snd_ctl_ext_t *ext, int subscribe)
{
	struct rs6_jack *j = ext->private_data;

	j->subscribed = subscribe;
}

static int jack_read_event(snd_ctl_ext_t *ext, snd_ctl_elem_id_t *id, unsigned int *event_mask)
{
	struct rs6_jack *j = ext->private_data;
	unsigned int k;
	int err;

	if (!j->pending) {
		err = rs6_target_events(&j->tgt);
		if (err < 0)
			return err;
		if (err > 0 && refresh(j) > 0)
			j->pending = (1u << NUM_JACKS) - 1;
	}
	if (!j->pending || !j->subscribed) {
		j->pending = 0;
		return -EAGAIN;
	}
	for (k = 0; !(j->pending & 1u << k); k++)
		;
	j->pending &= ~(1u << k);
	snd_ctl_elem_id_clear(id);
	snd_ctl_elem_id_set_numid(id, k + 1);
	snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_CARD);
	snd_ctl_elem_id_set_name(id, jack_names[k]);
	*event_mask = SND_CTL_EVENT_MASK_VALUE;
	return 1;
}

static int jack_poll_revents(snd_ctl_ext_t *ext, struct pollfd *pfd, unsigned int nfds,
			     unsigned short *revents)
{
	struct rs6_jack *j = ext->private_data;

	(void)nfds;
	*revents = pfd->revents;
	if (j->pending)
		*revents |= POLLIN;
	return 0;
}

static const snd_ctl_ext_callback_t jack_ops = {
	.close = jack_close,
	.elem_count = jack_elem_count,
	.elem_list = jack_elem_list,
	.find_elem = jack_find_elem,
	.get_attribute = jack_get_attribute,
	.get_integer_info = jack_get_integer_info,
	.read_integer = jack_read_integer,
	.subscribe_events = jack_subscribe_events,
	.read_event = jack_read_event,
	.poll_revents = jack_poll_revents,
};

SND_CTL_PLUGIN_DEFINE_FUNC(rs6_jack)
{
	snd_config_iterator_t i, next;
	const char *card = "HiByRS6", *ctl = NULL;
	char cardbuf[32], *ctl_name = NULL, hwid[64];
	struct rs6_jack *j;
	int err, idx;

	(void)root;
	snd_config_for_each(i, next, conf) {
		snd_config_t *n = snd_config_iterator_entry(i);
		const char *id;
		long v;

		if (snd_config_get_id(n, &id) < 0)
			continue;
		if (!strcmp(id, "comment") || !strcmp(id, "type") || !strcmp(id, "hint"))
			continue;
		if (!strcmp(id, "card")) {
			if (snd_config_get_integer(n, &v) >= 0) {
				snprintf(cardbuf, sizeof(cardbuf), "%ld", v);
				card = cardbuf;
			} else if (snd_config_get_string(n, &card) < 0) {
				SNDERR("rs6_jack: invalid card");
				return -EINVAL;
			}
			continue;
		}
		if (!strcmp(id, "ctl")) {
			if (snd_config_get_string(n, &ctl) < 0) {
				SNDERR("rs6_jack: invalid ctl");
				return -EINVAL;
			}
			continue;
		}
		SNDERR("rs6_jack: unknown field %s", id);
		return -EINVAL;
	}

	j = calloc(1, sizeof(*j));
	if (!j)
		return -ENOMEM;
	if (!ctl) {
		if (asprintf(&ctl_name, "hw:CARD=%s", card) < 0) {
			free(j);
			return -ENOMEM;
		}
		ctl = ctl_name;
	}
	err = rs6_target_open(&j->tgt, ctl);
	if (err < 0) {
		SNDERR("rs6_jack: no \"%s\" control on %s: %s", RS6_TARGET_CTL_NAME, ctl,
		       snd_strerror(err));
		free(ctl_name);
		free(j);
		return err;
	}
	free(ctl_name);
	j->spdif = rs6_target_is_spdif(&j->tgt) == 1;

	j->ext.version = SND_CTL_EXT_VERSION;
	if (rs6_target_card(&j->tgt, &idx, hwid, sizeof(hwid)) < 0) {
		idx = -1;
		hwid[0] = 0;
	}
	j->ext.card_idx = idx;
	snprintf(j->ext.id, sizeof(j->ext.id), "%s", hwid);
	snprintf(j->ext.driver, sizeof(j->ext.driver), "rs6_jack");
	snprintf(j->ext.name, sizeof(j->ext.name), "HiBy RS6 outputs");
	snprintf(j->ext.longname, sizeof(j->ext.longname),
		 "HiBy RS6 output jacks from Output Target (%s)", hwid);
	snprintf(j->ext.mixername, sizeof(j->ext.mixername), "rs6_jack");
	j->ext.poll_fd = rs6_target_fd(&j->tgt);
	j->ext.callback = &jack_ops;
	j->ext.private_data = j;

	err = snd_ctl_ext_create(&j->ext, name, mode);
	if (err < 0) {
		rs6_target_close(&j->tgt);
		free(j);
		return err;
	}
	*handlep = j->ext.handle;
	return 0;
}

SND_CTL_PLUGIN_SYMBOL(rs6_jack);
