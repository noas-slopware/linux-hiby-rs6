-- HiBy RS6: hand the card's playback PCM to the other output at once.
--
-- The DAC sink (UCM Headphones, hw PCM) and the coax sink (UCM SPDIF, the rs6_spdif encoder)
-- share the card's one playback PCM. When a jack is plugged or unplugged, the kernel's
-- Output Target moves, the rs6_jack controls mark the old sink's route unavailable and
-- WirePlumber moves the streams to the other sink. The old sink would hold the PCM until its
-- idle suspend (5 s), and the new sink could not open it until then. Suspend a sink of this
-- card at once when it goes idle with no available route. (The coax sink releases the PCM by
-- itself the moment the target moves; this is for the DAC sink on unplug.)

lutils = require ("linking-utils")
log = Log.open_topic ("s-node")

SimpleEventHook {
  name = "hiby-rs6/output-handover",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-state-changed" },
      Constraint { "media.class", "=", "Audio/Sink" },
      Constraint { "api.alsa.card.name", "=", "HiBy RS6" },
    },
  },
  execute = function (event)
    local node = event:get_subject ()
    local new_state = event:get_properties ()["event.subject.new-state"]

    if new_state ~= "idle" then
      return
    end

    local devices_om = event:get_source ():call ("get-object-manager", "device")
    if lutils.haveAvailableRoutes (node.properties, devices_om) then
      return
    end

    log:info (node, "output moved away; suspending to free the card PCM")
    node:send_command ("Suspend")
  end
}:register ()
