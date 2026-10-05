# Design docs

This directory is the **canonical** home of the design spec and implementation
plan for this project. Earlier in phase 1 these were mirrored from a separate
coordination directory, which let the copies here drift: the published plan
told readers to use a `priorityGroups[].backends` field that does not exist and
fails CRD admission, while the repo's own manifests used the correct
`backendRefs`. Edit these files here, and nowhere else.
