#!/usr/bin/env python3
"""Generate values.schema.json from values.yaml (converted to JSON by yq).

    yq -o=json values.yaml | python3 hack/gen-schema.py > values.schema.json

Structure and types come from the defaults; the tables below add what
cannot be inferred: free-form maps, enums, formats and descriptions.
Unknown keys are rejected everywhere else, so typos fail at install time.
"""
import json
import sys

# Maps whose keys are chosen by the user (labels, k8s objects, Mautic params).
FREE_FORM = {
    "commonLabels", "commonAnnotations",
    "global.nodeSelector", "global.affinity", "global.podLabels", "global.podAnnotations",
    "mautic.configParameters", "mautic.saml.idpMetadataFrom", "mautic.postal.publicKeyFrom", "mautic.ipLookup.authFrom",
    "web.strategy", "web.lifecycle", "web.podAnnotations", "web.podLabels", "web.nodeSelector", "web.affinity",
    "web.startupProbe", "web.readinessProbe", "web.livenessProbe",
    "worker.podAnnotations", "worker.podLabels", "worker.nodeSelector", "worker.affinity",
    "cron.podAnnotations", "cron.podLabels", "cron.nodeSelector", "cron.affinity", "cron.jobs",
    "cron.defaults.resources",
    "persistence.annotations", "service.annotations", "ingress.annotations", "httpRoute.annotations",
    "networkPolicy.egress.dnsSelector",
    "mariadb.podAnnotations", "mariadb.podLabels", "mariadb.nodeSelector", "mariadb.affinity",
    "valkey.podAnnotations", "valkey.podLabels", "valkey.nodeSelector", "valkey.affinity",
    "backup.podAnnotations", "backup.podLabels", "backup.nodeSelector", "backup.affinity",
    "backup.secretEnv", "backup.configMapEnv", "backup.dumpImage",
    "serviceAccount.annotations", "podSecurityContext", "containerSecurityContext",
}
RESOURCES = {"web.resources", "init.resources", "worker.resources", "mariadb.resources", "valkey.resources",
             "backup.resources", "test.resources"}

PULL_POLICY = {"type": "string", "enum": ["Always", "IfNotPresent", "Never"]}
ACCESS_MODES = {"type": "array", "minItems": 1,
                "items": {"type": "string", "enum": ["ReadWriteOnce", "ReadOnlyMany", "ReadWriteMany", "ReadWriteOncePod"]}}
QUANTITY = {"type": ["string", "integer"], "pattern": "^[0-9]+(\\.[0-9]+)?([EPTGMK]i?|[mkMGTPE])?$"}
CRON = {"type": "string", "pattern": "^(@(yearly|annually|monthly|weekly|daily|midnight|hourly)|(\\S+\\s+){4}\\S+)$"}
INT_OR_STR = {"type": ["integer", "string"]}

OVERRIDES = {
    "mautic.siteUrl": {"type": "string", "pattern": "^(https?://.+)?$",
                       "description": "Public URL of the instance, e.g. https://mautic.example.com (required)."},
    "image.pullPolicy": PULL_POLICY, "mariadb.image.pullPolicy": PULL_POLICY,
    "backup.resticImage.pullPolicy": PULL_POLICY, "valkey.image.pullPolicy": PULL_POLICY,
    "image.digest": {"type": "string", "pattern": "^(sha256:[a-f0-9]{64})?$"},
    "image.tag": INT_OR_STR, "mariadb.image.tag": INT_OR_STR, "valkey.image.tag": INT_OR_STR, "backup.resticImage.tag": INT_OR_STR,
    "service.type": {"type": "string", "enum": ["ClusterIP", "NodePort", "LoadBalancer"]},
    "service.port": {"type": "integer", "minimum": 1, "maximum": 65535},
    "persistence.accessModes": ACCESS_MODES, "mariadb.persistence.accessModes": ACCESS_MODES,
    "persistence.size": QUANTITY, "mariadb.persistence.size": QUANTITY,
    "ephemeral.tmpSizeLimit": QUANTITY, "ephemeral.varSizeLimit": QUANTITY, "backup.dumpSizeLimit": QUANTITY,
    "backup.schedule": CRON,
    "externalDatabase.port": {"type": ["integer", "string"]},
    "mautic.php.maxExecutionTime": INT_OR_STR,
    "mautic.saml.defaultRoleId": INT_OR_STR,
    "worker.memoryLimit": {"type": "string", "pattern": "^[0-9]+[KMG]?$"},
    "mautic.trustedProxies": {"type": "array", "items": {"type": "string"}},
    "worker.transports": {"type": "array", "minItems": 1, "items": {"type": "string"}},
    "mautic.cors.validDomains": {"type": "array", "items": {"type": "string", "pattern": "^https?://[^/]+$"}},
    "mautic.oauth.redirectHosts": {"type": "array", "items": {"type": "string", "pattern": "^[A-Za-z0-9.-]+$"}},
    "mautic.roles": {"type": "array", "items": {
        "type": "object", "additionalProperties": False, "required": ["name"],
        "properties": {
            "name": {"type": "string", "minLength": 1, "maxLength": 191},
            "description": {"type": "string"},
            "isAdmin": {"type": "boolean"},
            "permissions": {"type": "object",
                            "propertyNames": {"pattern": "^[a-z0-9_]+:[a-z0-9_]+$"},
                            "additionalProperties": {"type": "array", "minItems": 1, "items": {"type": "string"}}},
        }}},
    "mautic.oauth.resource": {"type": "string", "pattern": "^(https?://.+)?$"},
    "valkey.maxmemory": {"type": "string", "pattern": "^[0-9]+(b|kb|mb|gb)?$"},
    "web.replicaCount": {"type": "integer", "minimum": 0},
    "worker.replicaCount": {"type": "integer", "minimum": 0},
}


def schema_for(value, path):
    if path in OVERRIDES:
        return dict(OVERRIDES[path])
    if path in RESOURCES:
        return {"type": "object", "additionalProperties": False,
                "properties": {k: {"type": "object", "additionalProperties": QUANTITY}
                               for k in ("requests", "limits", "claims")}}
    if path in FREE_FORM:
        return {"type": "object"}
    if isinstance(value, bool):
        return {"type": "boolean"}
    if isinstance(value, int):
        return {"type": "integer"}
    if isinstance(value, str):
        return {"type": "string"}
    if isinstance(value, list):
        return {"type": "array"}
    if isinstance(value, dict):
        return {
            "type": "object",
            "additionalProperties": False,
            "properties": {k: schema_for(v, f"{path}.{k}" if path else k) for k, v in value.items()},
        }
    return {}


values = json.load(sys.stdin)
schema = schema_for(values, "")
schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
schema["title"] = "mautic Helm chart values"
# Helm passes this key to subcharts; accept it.
schema["properties"].setdefault("global", {"type": "object"})
json.dump(schema, sys.stdout, indent=2)
sys.stdout.write("\n")
