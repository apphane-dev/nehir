---
"nehir": patch
---

Stop treating app-managed transient floating windows as user-addressable

App-managed ephemeral surfaces — menus, popovers, and rapidly-recreated helper
windows such as a Teams or Zoom call mini-window — are now classified as not
user-addressable when their AX facts do not look like a normal standard window.
Transient windows with normal standard-window affordances, such as Zoom's full
call window, remain user-addressable.

- Helper/PIP-style transient surfaces no longer appear as floating-window icons
  in the workspace bar, and the "toggle focused window floating" command no
  longer force-tiles them — so they can no longer be assigned into the tiled
  tree, which the owning app would then destroy and recreate, orphaning the
  assignment.
- WindowServer-parented child surfaces now follow niri's model: they are treated
  as child UI of their parent and auto-float instead of entering the tiled tree.
  When their parent is already tracked, they inherit the parent's workspace.
- A newly-created helper/PIP-style transient floating surface now binds to its
  owning app's primary workspace instead of the currently-viewed workspace, so it
  no longer "leaks" onto the workspace you happen to be looking at, and can no
  longer anchor managed focus there to drag later app windows across.
