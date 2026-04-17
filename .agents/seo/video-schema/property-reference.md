<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Property Reference

| Property | Type | Notes |
|----------|------|-------|
| `name` | Text | Required; match page H1 |
| `description` | Text | Required; 150–300 chars |
| `thumbnailUrl` | URL | Required; min 1280×720 |
| `uploadDate` | ISO 8601 | Required |
| `duration` | ISO 8601 duration | `PT8M30S` = 8 min 30 sec |
| `contentUrl` | URL | Direct video file URL |
| `embedUrl` | URL | YouTube/Vimeo embed URL |
| `hasPart` | Clip[] | Key Moments segments |
