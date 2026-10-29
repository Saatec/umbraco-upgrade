---
type: regex
target: { source: file, path: Backoffice/ExportApiController.cs }
pattern: 'class ExportApiController\b'
---

The export controller still exists after the run. A port may change its base class; deleting the file or the class fails.
