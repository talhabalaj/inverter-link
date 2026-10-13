# 3D scrolling review

Changes retained in build `20261013.5`:

- Label projection moved out of the 30 Hz particle loop. Labels now follow house rotation, view layout changes and readings.
- Identical box and particle meshes share resources. Window, panel and cable materials update only when their energy state changes.
- Other tabs/inactive app states stop particle timers. The house, camera and lights stay enabled. Build `20261013.3` hid the entire render view and disabled its root anchor; a hosted Home-screen Release test reproduced a blank model during an inactive transition. Build `20261013.5` removes that visibility coupling and the viewport/appearance state gate that failed to restart animation in a hosted Home lifecycle test. Moving particles continue while scrolling within Home; reliable offscreen GPU suspension is deferred.
- Disabled camera grain, depth of field and motion blur; the geometry, architectural lighting and live flow remain.

Scene lifecycle tests exercise active → inactive → active transitions, Reduce Motion and disconnection. A SwiftUI-hosted Home regression checks that the render view and root anchor remain visible while particle animation pauses/restores without rebuilding the model.

**No measured FPS improvement is claimed.** The native profiler hung while recording on this Xcode setup. Its export failed with `Document Missing Template Error`, so CPU/hang comparisons were unavailable. The simulator was offline during the profiling attempt and cannot establish performance on the physical iPhone.

The updated Home, scan/IP actions and address sheet were visually checked in the simulator. Device-side scrolling and the actual iOS background-time limit still need verification on the iPhone.

If scrolling is still slow on the phone, the next investigation is a device-side render trace: the remaining likely costs are the many geometry entities, directional shadows and point lights. Static geometry batching or simpler lighting should follow that evidence rather than a broad model redesign.
