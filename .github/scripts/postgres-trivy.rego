package trivy

import rego.v1

# KSV-0109 flags the name of the validator and the ALTER ROLE ... PASSWORD
# statements in this reviewed script bundle. Values come from a mounted Secret.
# The Kustomize content hash changes when any bootstrap file changes.
ignore if {
    input.ID == "KSV-0109"
    startswith(input.Message, "ConfigMap 'dv-ayan-kassen-1951-postgres-bootstrap-kk8bbb26k8' in 'dv-ayan-kassen-1951' namespace ")
}
