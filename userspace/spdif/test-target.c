// SPDX-License-Identifier: MIT
/*
 * Output Target handling, against a stand-in for the hm100 control: a user-defined
 * "Output Target" enum (the kernel's item names) added to the card named by
 * RS6_TEST_CTL_CARD (e.g. "0") for the duration of the test and removed afterwards.
 * Skipped when the variable is unset (build chroots have no sound card).
 *
 *   - rs6_jack: "SPDIF Jack"/"DAC Jack" follow the target, with a value event per jack
 *   - rs6_spdif: writes reach the card PCM while the target is Spdif, nothing reaches it
 *     after the target moves (the card PCM is closed, time keeps running), and it is
 *     reopened when the target is Spdif again
 *   - the card PCM is not opened while the target is not Spdif
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <alsa/asoundlib.h>

static int failures;
static const char *capture;

#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: " __VA_ARGS__); printf("\n"); failures++; } } while (0)

static const char *const items[] = { "Lineout", "Headset", "Balance", "BalanceLo", "Spdif" };

static long fsize(void)
{
	struct stat st;

	return stat(capture, &st) ? -1 : st.st_size;
}

static int attached(snd_pcm_t *pcm)
{
	snd_output_t *out;
	char *text;
	int ret;

	snd_output_buffer_open(&out);
	snd_pcm_dump(pcm, out);
	snd_output_buffer_string(out, &text);
	ret = strstr(text, ", attached,") != NULL;
	snd_output_close(out);
	return ret;
}

static int set_target(snd_ctl_t *ctl, snd_ctl_elem_id_t *id, unsigned int item)
{
	snd_ctl_elem_value_t *v;

	snd_ctl_elem_value_alloca(&v);
	snd_ctl_elem_value_set_id(v, id);
	snd_ctl_elem_value_set_enumerated(v, 0, item);
	return snd_ctl_elem_write(ctl, v);
}

static long jack(snd_ctl_t *j, const char *name)
{
	snd_ctl_elem_value_t *v;
	snd_ctl_elem_id_t *id;

	snd_ctl_elem_id_alloca(&id);
	snd_ctl_elem_value_alloca(&v);
	snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_CARD);
	snd_ctl_elem_id_set_name(id, name);
	snd_ctl_elem_value_set_id(v, id);
	if (snd_ctl_elem_read(j, v) < 0)
		return -1;
	return snd_ctl_elem_value_get_boolean(v, 0);
}

/* jack events: wait up to 1 s, return how many value events arrived for the two jacks */
static int jack_events(snd_ctl_t *j)
{
	struct pollfd pfd[4];
	snd_ctl_event_t *ev;
	int n = snd_ctl_poll_descriptors(j, pfd, 4), got = 0, err;
	unsigned short rev;

	snd_ctl_event_alloca(&ev);
	if (poll(pfd, n, 1000) <= 0)
		return 0;
	snd_ctl_poll_descriptors_revents(j, pfd, n, &rev);
	while ((err = snd_ctl_read(j, ev)) > 0) {
		const char *name = snd_ctl_event_elem_get_name(ev);

		if (snd_ctl_event_elem_get_mask(ev) & SND_CTL_EVENT_MASK_VALUE &&
		    (!strcmp(name, "SPDIF Jack") || !strcmp(name, "DAC Jack")))
			got++;
	}
	return got;
}

static int hctl_hits;

static int hctl_cb(snd_hctl_elem_t *elem, unsigned int mask)
{
	(void)elem;
	if (mask & SND_CTL_EVENT_MASK_VALUE)
		hctl_hits++;
	return 0;
}

/*
 * What PipeWire's ACP does with a UCM JackCTL: snd_hctl_open on the plugin, load, find the
 * CARD-iface "SPDIF Jack", read it as a boolean, get element callbacks from poll + events.
 */
static void test_hctl(const char *jackname, snd_ctl_t *hw, snd_ctl_elem_id_t *tid)
{
	snd_hctl_t *h;
	snd_hctl_elem_t *e;
	snd_ctl_elem_id_t *id;
	snd_ctl_elem_value_t *v;
	struct pollfd pfd[4];
	int n, err;

	snd_ctl_elem_id_alloca(&id);
	snd_ctl_elem_value_alloca(&v);
	if ((err = snd_hctl_open(&h, jackname, 0)) < 0 || (err = snd_hctl_load(h)) < 0) {
		CHECK(0, "hctl %s: %s", jackname, snd_strerror(err));
		return;
	}
	snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_CARD);
	snd_ctl_elem_id_set_name(id, "SPDIF Jack");
	e = snd_hctl_find_elem(h, id);
	CHECK(e, "hctl: no SPDIF Jack");
	if (!e)
		goto out;
	snd_hctl_elem_set_callback(e, hctl_cb);
	set_target(hw, tid, 3);
	n = snd_hctl_poll_descriptors(h, pfd, 4);
	CHECK(poll(pfd, n, 1000) > 0, "hctl: no poll wakeup");
	snd_hctl_handle_events(h);
	CHECK(hctl_hits == 1, "hctl: %d SPDIF Jack callbacks", hctl_hits);
	snd_hctl_elem_read(e, v);
	CHECK(snd_ctl_elem_value_get_boolean(v, 0) == 0, "hctl: SPDIF Jack still on");
	set_target(hw, tid, 4);
	poll(pfd, n, 1000);
	snd_hctl_handle_events(h);
	snd_hctl_elem_read(e, v);
	CHECK(hctl_hits == 2 && snd_ctl_elem_value_get_boolean(v, 0) == 1, "hctl: back to Spdif");
out:
	snd_hctl_close(h);
}

static int write_secs(snd_pcm_t *pcm, double secs)
{
	static int16_t buf[480 * 2];
	long frames = secs * 48000;

	while (frames > 0) {
		snd_pcm_sframes_t w = snd_pcm_writei(pcm, buf, frames < 480 ? frames : 480);

		if (w < 0)
			return w;
		frames -= w;
	}
	return 0;
}

int main(void)
{
	const char *card = getenv("RS6_TEST_CTL_CARD");
	char ctlname[64], pcmname[96], jackname[96];
	snd_ctl_t *hw = NULL, *j = NULL;
	snd_pcm_t *pcm = NULL;
	snd_ctl_elem_id_t *id;
	snd_pcm_hw_params_t *hwp;
	long s0, s1, s2;
	int err;

	capture = getenv("RS6_TEST_CAPTURE");
	if (!card || !capture) {
		printf("target: skipped (set RS6_TEST_CTL_CARD to a card index to run it)\n");
		return 77;
	}
	snprintf(ctlname, sizeof(ctlname), "hw:%s", card);
	snprintf(pcmname, sizeof(pcmname), "rs6tgt:CARD=%s", card);
	snprintf(jackname, sizeof(jackname), "rs6tgtjack:CARD=%s", card);

	snd_ctl_elem_id_alloca(&id);
	snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_MIXER);
	snd_ctl_elem_id_set_name(id, "Output Target");
	if ((err = snd_ctl_open(&hw, ctlname, 0)) < 0 ||
	    (err = snd_ctl_elem_add_enumerated(hw, id, 1, 5, items)) < 0) {
		printf("cannot add the stand-in control on %s: %s\n", ctlname, snd_strerror(err));
		return 1;
	}

	/* Spdif: jacks */
	set_target(hw, id, 4);
	if ((err = snd_ctl_open(&j, jackname, SND_CTL_NONBLOCK)) < 0) {
		CHECK(0, "open %s: %s", jackname, snd_strerror(err));
		goto out;
	}
	snd_ctl_subscribe_events(j, 1);
	CHECK(jack(j, "SPDIF Jack") == 1 && jack(j, "DAC Jack") == 0, "jacks at Spdif");
	test_hctl(jackname, hw, id);
	jack_events(j);		/* the two switches above */

	/* not Spdif at open: the card PCM stays closed, time runs */
	set_target(hw, id, 1);
	CHECK(jack_events(j) == 2, "two jack events for Spdif -> Headset");
	CHECK(jack(j, "SPDIF Jack") == 0 && jack(j, "DAC Jack") == 1, "jacks at Headset");
	{
		int fd = open(capture, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
		char num[16];

		snprintf(num, sizeof(num), "%d", fd);
		setenv("RS6_TEST_CAPTURE_FD", num, 1);
	}
	if ((err = snd_pcm_open(&pcm, pcmname, SND_PCM_STREAM_PLAYBACK, 0)) < 0) {
		CHECK(0, "open %s: %s", pcmname, snd_strerror(err));
		goto out;
	}
	snd_pcm_hw_params_alloca(&hwp);
	snd_pcm_hw_params_any(pcm, hwp);
	snd_pcm_hw_params_set_access(pcm, hwp, SND_PCM_ACCESS_RW_INTERLEAVED);
	snd_pcm_hw_params_set_format(pcm, hwp, SND_PCM_FORMAT_S16_LE);
	snd_pcm_hw_params_set_channels(pcm, hwp, 2);
	snd_pcm_hw_params_set_rate(pcm, hwp, 48000, 0);
	snd_pcm_hw_params_set_period_size(pcm, hwp, 480, 0);
	snd_pcm_hw_params_set_buffer_size(pcm, hwp, 1920);
	if ((err = snd_pcm_hw_params(pcm, hwp)) < 0) {
		CHECK(0, "hw_params: %s", snd_strerror(err));
		goto out;
	}
	CHECK(write_secs(pcm, 0.2) == 0, "write while Headset");
	CHECK(!attached(pcm) && fsize() == 0, "card PCM opened while the target is not Spdif");

	/* Spdif: attached, data reaches the card PCM */
	set_target(hw, id, 4);
	CHECK(jack_events(j) == 2, "two jack events for Headset -> Spdif");
	CHECK(write_secs(pcm, 0.2) == 0, "write while Spdif");
	CHECK(attached(pcm), "card PCM not opened at Spdif");

	/* jack plugged: detached, nothing more reaches it, writes keep pace */
	set_target(hw, id, 2);
	CHECK(write_secs(pcm, 0.2) == 0, "write after Balance");
	CHECK(!attached(pcm), "card PCM still open after the target moved");
	s0 = s1 = fsize();	/* closed: everything sent is in the file now */
	CHECK(s0 > 0, "nothing reached the card PCM at Spdif");
	CHECK(write_secs(pcm, 0.2) == 0, "write after Balance");
	s2 = fsize();
	CHECK(s1 == s2, "card PCM still written after the target moved (%ld -> %ld)", s1, s2);

	/* back to Spdif: reopened (the file PCM starts a new file) */
	set_target(hw, id, 4);
	CHECK(write_secs(pcm, 0.3) == 0, "write after Spdif again");
	CHECK(attached(pcm), "card PCM not reopened at Spdif");
	CHECK(snd_pcm_drain(pcm) == 0, "drain");
	snd_pcm_close(pcm);
	pcm = NULL;
	CHECK(fsize() > s2, "nothing reached the reopened card PCM (%ld)", fsize());
	printf("target: capture %ld bytes at Spdif, %ld after the switch away (unchanged: %s)\n",
	       s0, s2, s1 == s2 ? "yes" : "no");

out:
	if (pcm)
		snd_pcm_close(pcm);
	if (j)
		snd_ctl_close(j);
	snd_ctl_elem_remove(hw, id);
	snd_ctl_close(hw);
	if (failures) {
		printf("%d failure(s)\n", failures);
		return 1;
	}
	printf("target: Output Target switching ok (jack controls, detach, reattach)\n");
	return 0;
}
