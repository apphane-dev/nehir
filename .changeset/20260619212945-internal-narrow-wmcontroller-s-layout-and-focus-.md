---
"nehir": none

---

Internal: narrow WMController's layout and focus surface behind LayoutCoordinator and FocusCoordinator protocols, funnel engine writes through setNiriEngine(_:), so command and event handlers no longer reach into the live niriEngine or the concrete NiriLayoutHandler.
