# Mise en page du .dmg (dmgbuild). Appelé par scripts/make-dmg.sh avec -D app=… -D uninstaller=… -D readme=… -D background=…
import os
app = defines["app"]
uninstaller = defines["uninstaller"]
readme = defines["readme"]

format = "UDZO"
filesystem = "HFS+"
files = [app, uninstaller, readme]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
window_rect = ((200, 120), (640, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 96
text_size = 12
icon_locations = {
    os.path.basename(app): (170, 200),
    "Applications": (470, 200),
    os.path.basename(uninstaller): (110, 372),
    os.path.basename(readme): (530, 372),
}
hide_extension = [os.path.basename(app), os.path.basename(uninstaller), os.path.basename(readme)]
