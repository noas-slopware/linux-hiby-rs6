# Desktop files in /usr/share/hiby-rs6 (Firefox with the RS6 V4L2 fix) win over the stock ones.
# Plasma drops XDG_* variables from the systemd user environment unless startplasma itself has
# them (startplasma.cpp dropSessionVarsFromSystemdEnvironment), so environment.d alone never
# reaches plasmashell; startplasma sources this before it syncs the environment.
case ":${XDG_DATA_DIRS}:" in
*:/usr/share/hiby-rs6:*) ;;
*) export XDG_DATA_DIRS="/usr/share/hiby-rs6:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" ;;
esac
