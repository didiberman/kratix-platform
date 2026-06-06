import { createBackendModule } from "@backstage/backend-plugin-api";
import { scaffolderActionsExtensionPoint } from "@backstage/plugin-scaffolder-node";
import { createTemplateAction } from "@backstage/plugin-scaffolder-node";
import * as https from "https";
import * as http from "http";
import * as fs from "fs";

function k8sRequest(
  token: string,
  ca: Buffer,
  method: string,
  path: string,
  body?: string,
): Promise<{ statusCode: number; data: string }> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string | number> = {
      Authorization: `Bearer ${token}`,
    };
    if (body) {
      headers["Content-Type"] = "application/json";
      headers["Content-Length"] = Buffer.byteLength(body);
    }
    const req = https.request(
      { hostname: "kubernetes.default.svc", port: 443, path, method, headers, ca },
      res => {
        let data = "";
        res.on("data", chunk => (data += chunk));
        res.on("end", () => resolve({ statusCode: res.statusCode ?? 0, data }));
      },
    );
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

async function discoverPlural(
  token: string,
  ca: Buffer,
  group: string,
  version: string,
  kind: string,
): Promise<string> {
  try {
    const apiPath = group ? `/apis/${group}/${version}` : `/api/${version}`;
    const { statusCode, data } = await k8sRequest(token, ca, "GET", apiPath);
    if (statusCode === 200) {
      const apiList = JSON.parse(data);
      const resource = (apiList.resources || []).find((r: any) => r.kind === kind);
      if (resource?.name) return resource.name;
    }
  } catch {
    // fall through to default
  }
  return kind.toLowerCase() + "s";
}

function minioRequest(
  method: string,
  bucket: string,
  objectPath: string,
  body?: string,
): Promise<{ statusCode: number; data: string }> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string | number> = {};
    if (body) {
      headers["Content-Type"] = "application/octet-stream";
      headers["Content-Length"] = Buffer.byteLength(body);
    }
    const req = http.request(
      {
        hostname: "minio.minio-system.svc.cluster.local",
        port: 9000,
        path: `/${bucket}/${objectPath}`,
        method,
        headers,
      },
      res => {
        let data = "";
        res.on("data", chunk => (data += chunk));
        res.on("end", () => resolve({ statusCode: res.statusCode ?? 0, data }));
      },
    );
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

// Use the (z) => schema factory so Backstage passes its own zod v3 instance,
// avoiding version mismatches with any zod v4 in node_modules.
const createResourceRequestAction = () =>
  createTemplateAction({
    id: "kratix:resourcerequest:create",
    description: "Submit a Kratix ResourceRequest to the platform cluster",
    schema: {
      input: (z: any) =>
        z.object({
          name: z.string(),
          namespace: z.string().optional().default("default"),
          apiVersion: z.string(),
          kind: z.string(),
          spec: z.record(z.any()).optional().default({}),
        }),
    },
    async handler(ctx) {
      const { name, namespace, apiVersion, kind, spec } = ctx.input as {
        name: string;
        namespace: string;
        apiVersion: string;
        kind: string;
        spec: Record<string, any>;
      };
      const tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token";
      const caPath = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt";
      if (!fs.existsSync(tokenPath)) throw new Error("No service account token");
      const token = fs.readFileSync(tokenPath, "utf8").trim();
      const ca = fs.readFileSync(caPath);
      const [group, version] = apiVersion.includes("/") ? apiVersion.split("/") : ["", apiVersion];
      const plural = await discoverPlural(token, ca, group, version, kind);
      ctx.logger.info(`Discovered plural for ${kind}: ${plural}`);
      const apiPath = group
        ? `/apis/${group}/${version}/namespaces/${namespace}/${plural}`
        : `/api/${version}/namespaces/${namespace}/${plural}`;
      const body = JSON.stringify({ apiVersion, kind, metadata: { name, namespace }, spec });
      ctx.logger.info(`POST ${apiPath} — ${kind}/${name}`);
      const { statusCode, data } = await k8sRequest(token, ca, "POST", apiPath, body);
      if (statusCode >= 200 && statusCode < 300) {
        ctx.logger.info(`Created ${kind}/${name} — HTTP ${statusCode}`);
      } else {
        throw new Error(`Kubernetes API ${statusCode}: ${data}`);
      }
    },
  });

const deleteResourceRequestAction = () =>
  createTemplateAction({
    id: "kratix:resourcerequest:delete",
    description: "Delete a Kratix ResourceRequest from the platform cluster",
    schema: {
      input: (z: any) =>
        z.object({
          name: z.string(),
          namespace: z.string().optional().default("default"),
          apiVersion: z.string(),
          kind: z.string(),
        }),
    },
    async handler(ctx) {
      const { name, namespace, apiVersion, kind } = ctx.input as {
        name: string;
        namespace: string;
        apiVersion: string;
        kind: string;
      };
      const tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token";
      const caPath = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt";
      if (!fs.existsSync(tokenPath)) throw new Error("No service account token");
      const token = fs.readFileSync(tokenPath, "utf8").trim();
      const ca = fs.readFileSync(caPath);
      const [group, version] = apiVersion.includes("/") ? apiVersion.split("/") : ["", apiVersion];
      const plural = await discoverPlural(token, ca, group, version, kind);
      const apiPath = group
        ? `/apis/${group}/${version}/namespaces/${namespace}/${plural}/${name}`
        : `/api/${version}/namespaces/${namespace}/${plural}/${name}`;
      ctx.logger.info(`DELETE ${apiPath}`);
      const { statusCode, data } = await k8sRequest(token, ca, "DELETE", apiPath);
      if (statusCode >= 200 && statusCode < 300) {
        ctx.logger.info(`Deleted ${kind}/${name} — HTTP ${statusCode}`);
        try {
          await minioRequest("DELETE", "backstage-catalog", `nginx/${name}.yaml`);
          ctx.logger.info(`Removed catalog entry for ${name}`);
        } catch {
          ctx.logger.warn(`Could not remove catalog entry for ${name}`);
        }
      } else if (statusCode === 404) {
        throw new Error(`${kind}/${name} not found`);
      } else {
        throw new Error(`Kubernetes API ${statusCode}: ${data}`);
      }
    },
  });

const registerCatalogEntityAction = () =>
  createTemplateAction({
    id: "kratix:catalog:register",
    description: "Register a Kratix instance as a Backstage catalog entity via MinIO",
    schema: {
      input: (z: any) =>
        z.object({
          name: z.string(),
          promiseKind: z.string(),
          namespace: z.string().optional().default("default"),
          owner: z.string().optional().default("platform-team"),
          description: z.string().optional(),
        }),
    },
    async handler(ctx) {
      const { name, promiseKind, namespace, owner, description: descriptionInput } = ctx.input as {
        name: string;
        promiseKind: string;
        namespace: string;
        owner: string;
        description?: string;
      };
      const description = descriptionInput ?? `${promiseKind} instance provisioned via Kratix`;
      const lowerKind = promiseKind.toLowerCase();
      const catalogYaml = `apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: ${name}
  description: "${description}"
  annotations:
    backstage.io/kubernetes-id: "${name}-${lowerKind}"
    backstage.io/kubernetes-namespace: "${namespace}"
  tags:
    - ${lowerKind}
    - kratix
    - instance
spec:
  type: service
  lifecycle: production
  owner: "${owner}"
  dependsOn:
    - component:default/${lowerKind}-promise
`;
      const objectPath = `${lowerKind}/${name}.yaml`;
      ctx.logger.info(`Writing catalog entry to MinIO: backstage-catalog/${objectPath}`);
      const { statusCode } = await minioRequest("PUT", "backstage-catalog", objectPath, catalogYaml);
      if (statusCode >= 200 && statusCode < 300) {
        const url = `http://minio.minio-system.svc.cluster.local:9000/backstage-catalog/${objectPath}`;
        ctx.logger.info(`Catalog entry available at: ${url}`);
        ctx.output("catalogUrl", url);
      } else {
        ctx.logger.warn(`MinIO PUT returned ${statusCode} — catalog entry not registered`);
      }
    },
  });

const kratixScaffolderModule = createBackendModule({
  pluginId: "scaffolder",
  moduleId: "kratix-actions",
  register(env) {
    env.registerInit({
      deps: { scaffolder: scaffolderActionsExtensionPoint },
      async init({ scaffolder }) {
        scaffolder.addActions(
          createResourceRequestAction(),
          deleteResourceRequestAction(),
          registerCatalogEntityAction(),
        );
      },
    });
  },
});

export default kratixScaffolderModule;
