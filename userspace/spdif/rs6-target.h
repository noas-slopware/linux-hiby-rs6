/* SPDX-License-Identifier: MIT */
/*
 * The hm100 codec's read-only "Output Target" enum (docs/spdif-dsd.md 9.4): where a stream
 * opened now plays. "Spdif" means the coax output, which needs BMC-encoded data.
 */
#ifndef RS6_TARGET_H
#define RS6_TARGET_H

#include <alsa/asoundlib.h>

#define RS6_TARGET_CTL_NAME	"Output Target"
#define RS6_TARGET_SPDIF_ITEM	"Spdif"

struct rs6_target {
	snd_ctl_t *ctl;
	snd_ctl_elem_id_t *id;
	snd_ctl_elem_value_t *val;
	unsigned int numid;
	unsigned int spdif_item;
};

/* open ctl_name (e.g. "hw:CARD=HiByRS6"), find the control, subscribe to its events */
int rs6_target_open(struct rs6_target *t, const char *ctl_name);
void rs6_target_close(struct rs6_target *t);

/* 1 if the target is Spdif, 0 if not, negative on error (card gone) */
int rs6_target_is_spdif(struct rs6_target *t);

/*
 * Read all pending control events without blocking: 1 if one of them concerns Output Target
 * (or the card went away), 0 if none did, negative on error.
 */
int rs6_target_events(struct rs6_target *t);

/* the descriptor to poll for events (POLLIN) */
int rs6_target_fd(struct rs6_target *t);

/* card index and id of the control device, for the ctl plugin's card info */
int rs6_target_card(struct rs6_target *t, int *index, char *id, size_t id_len);

#endif
