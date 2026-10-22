-- HiBy RS6: the music player gets the DAC to itself.
--
-- The pipewire-pulse rule in 50-hiby-rs6.conf marks the music player's stream
-- node.exclusive. WirePlumber's own exclusive linking (linking/prepare-link)
-- refuses such a stream while anything else is linked to the target, and a
-- paused browser tab stays linked, so the player would stay silent. Unlink the
-- others first instead: they wait ("waiting reconnect") and relink on the
-- rescan when the exclusive stream goes away. A stream that starts while the
-- target is held exclusively waits the same way instead of getting a client
-- error.

lutils = require ("linking-utils")
cutils = require ("common-utils")
log = Log.open_topic ("s-linking")

SimpleEventHook {
  name = "hiby-rs6/exclusive-takeover",
  before = "linking/prepare-link",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-target" },
    },
  },
  execute = function (event)
    local _, om, si, si_props, si_flags, target =
        lutils:unwrap_select_target_event (event)

    if not target then
      return
    end

    if not cutils.parseBool (si_props ["node.exclusive"]) then
      local _, held = lutils.isLinked (target)
      if held then
        -- prepare-link then waits for the rescan instead of sending an error
        si_flags.was_handled = true
      end
      return
    end

    for l in om:iterate { type = "SiLink" } do
      local p = l.properties
      local out_id = tonumber (p ["out.item.id"])
      local in_id = tonumber (p ["in.item.id"])
      local other = nil

      if in_id == target.id then
        other = out_id
      elseif out_id == target.id then
        other = in_id
      end

      if other and other ~= si.id then
        log:info (si, "... exclusive: unlinking item " .. other .. " from the target")
        local flags = lutils:get_flags (other)
        flags.peer_id = nil
        flags.was_handled = true
        l:remove ()
      end
    end
  end
}:register ()
