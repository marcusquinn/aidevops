---
description: LiDAR, photographs, video and drawings as provenance-aware modelling inputs
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# 3D capture

## Capture contract

Identify the device, capture app/version, export formats, intended accuracy and
privacy boundary before scanning. Ordinary video must not be assumed to retain
exportable LiDAR/depth data. Depth that was not recorded cannot be recovered as
genuine sensor evidence by asking a model to infer it.

Supported input classes:

- Simple mesh/point-cloud export plus photographs and reference measurements.
- Rich RGB/depth capture with camera poses/intrinsics, timestamps, confidence,
  scale and coordinate metadata where the device/app exposes them.
- Overlapping images/video for photogrammetry with adequate coverage and texture.
- Drawings/sketches with known dimensions and explicit missing information.

Retain immutable originals separately from alignment, cleanup, reconstruction and
retopology. Record transform/scale corrections and which surfaces are inferred.
Inspect the actual file/container and metadata rather than inferring capabilities
from a phone's camera count or a file extension. Apple ARKit/RoomPlan-style capture
requires a compatible device/app; not every export preserves the raw capture.

## Accuracy and capture advice

Use varied viewpoints and known scale references, avoid motion blur, and document
occluded areas. Glass, mirrors, polished brass, dark/low-texture surfaces and thin
edges can defeat depth/reconstruction. Photographs and direct measurements may be
more useful than LiDAR for a banker's lamp.

For kitchens, capture room geometry, openings and service positions, then verify
critical dimensions independently. Do not quote universal millimetre accuracy:
validate the particular device, scan, registration and measurement workflow.
An attractive scan does not establish level/plumb, clearance or fabrication fit.

Photo-to-DXF tools such as the user-supplied [Facadetool](https://facadetool.com/)
are useful drafting inputs. A single photograph still needs scale/perspective
verification and cannot establish hidden depth. Acoustic scene interpretation is
speculative inspiration, never an as-built measurement source.

## Privacy and handoff

Interior scans can expose private possessions, people, locations and documents.
Keep them local by default; obtain upload authority for external reconstruction.
Hand off selected crops/views, relevant geometry, uncertainty and source IDs,
not the entire private capture in every agent prompt. Use `3d-workflows.md` for
the representation and `workflows/creative-production.md` for mode/evidence gates.
