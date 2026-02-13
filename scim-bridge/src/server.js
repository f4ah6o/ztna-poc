const express = require("express");
const client = require("prom-client");
const {
  getAdminToken,
  findUserByUsername,
  findUserById,
  upsertUser,
  setUserPassword,
  ensureGroup,
  addUserToGroup,
  upsertGroup,
} = require("./keycloak");
const {
  mapScimUserToKeycloak,
  mapScimGroupToModel,
  scimUserResponse,
  scimGroupResponse,
} = require("./scim-mapping");

const app = express();
const port = Number(process.env.PORT || 8080);
const bearerToken = process.env.SCIM_BRIDGE_TOKEN;
const defaultGroup = process.env.NB_DEMO_GROUP || "demo-users";
const metricsRegister = new client.Registry();

client.collectDefaultMetrics({
  register: metricsRegister,
  prefix: "scim_bridge_",
});

const httpRequestsTotal = new client.Counter({
  name: "http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["method", "route", "status"],
  registers: [metricsRegister],
});

const httpRequestDurationSeconds = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status"],
  buckets: [0.01, 0.05, 0.1, 0.3, 1, 3, 10],
  registers: [metricsRegister],
});

const scimKeycloakRequestFailuresTotal = new client.Counter({
  name: "scim_keycloak_request_failures_total",
  help: "Number of SCIM operations that failed due to Keycloak API/token errors",
  labelNames: ["operation"],
  registers: [metricsRegister],
});

if (!bearerToken) {
  throw new Error("SCIM_BRIDGE_TOKEN is required");
}

app.use(express.json({ limit: "2mb" }));

function normalizedRoute(req) {
  if (req.route?.path) return req.route.path;
  if (!req.path) return "unknown";
  return req.path
    .replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/gi, ":id")
    .replace(/\/\d+/g, "/:id");
}

app.use((req, res, next) => {
  const end = httpRequestDurationSeconds.startTimer();
  res.on("finish", () => {
    const route = normalizedRoute(req);
    const status = String(res.statusCode);
    const labels = { method: req.method, route, status };
    httpRequestsTotal.inc(labels);
    end(labels);
  });
  next();
});

app.use((req, res, next) => {
  if (req.path === "/healthz" || req.path === "/metrics") return next();

  const auth = req.headers.authorization || "";
  if (!auth.startsWith("Bearer ")) {
    return res.status(401).json({ error: "missing bearer token" });
  }

  const token = auth.slice("Bearer ".length);
  if (token !== bearerToken) {
    return res.status(403).json({ error: "invalid token" });
  }

  next();
});

app.get("/healthz", (_req, res) => {
  res.json({ status: "ok" });
});

app.get("/metrics", async (_req, res) => {
  res.set("Content-Type", metricsRegister.contentType);
  res.end(await metricsRegister.metrics());
});

function isKeycloakError(err) {
  return typeof err?.message === "string" && err.message.startsWith("Keycloak ");
}

app.post("/scim/v2/Users", async (req, res) => {
  try {
    const model = mapScimUserToKeycloak(req.body);
    const token = await getAdminToken();

    const upserted = await upsertUser(token, model);
    const userId = upserted.id;

    if (model.password) {
      await setUserPassword(token, userId, model.password);
    }

    const groupNames = model.groups.length > 0 ? model.groups : [defaultGroup];
    for (const groupName of groupNames) {
      const groupId = await ensureGroup(token, groupName);
      await addUserToGroup(token, userId, groupId);
    }

    const finalUser = await findUserById(token, userId);
    res.status(upserted.created ? 201 : 200).json(scimUserResponse(finalUser || model, userId));
  } catch (err) {
    if (isKeycloakError(err)) {
      scimKeycloakRequestFailuresTotal.inc({ operation: "create_user" });
    }
    res.status(400).json({ error: err.message });
  }
});

app.patch("/scim/v2/Users/:id", async (req, res) => {
  try {
    const token = await getAdminToken();
    const existing = await findUserById(token, req.params.id);
    if (!existing) {
      return res.status(404).json({ error: "user not found" });
    }

    // Minimal PATCH support for active/password/groups in demo.
    const operations = Array.isArray(req.body?.Operations) ? req.body.Operations : [];
    let enabled = existing.enabled;
    let newPassword;
    const groups = [];

    for (const op of operations) {
      if (op.path === "active") enabled = Boolean(op.value);
      if (op.path === "password") newPassword = String(op.value || "");
      if (op.path === "groups" && Array.isArray(op.value)) {
        for (const g of op.value) {
          if (g.display || g.value) groups.push(g.display || g.value);
        }
      }
    }

    await upsertUser(token, {
      username: existing.username,
      email: existing.email,
      firstName: existing.firstName,
      lastName: existing.lastName,
      enabled,
      attributes: existing.attributes || {},
      groups,
    });

    if (newPassword) {
      await setUserPassword(token, req.params.id, newPassword);
    }

    if (groups.length > 0) {
      for (const groupName of groups) {
        const groupId = await ensureGroup(token, groupName);
        await addUserToGroup(token, req.params.id, groupId);
      }
    }

    const finalUser = await findUserById(token, req.params.id);
    res.json(scimUserResponse(finalUser, req.params.id));
  } catch (err) {
    if (isKeycloakError(err)) {
      scimKeycloakRequestFailuresTotal.inc({ operation: "patch_user" });
    }
    res.status(400).json({ error: err.message });
  }
});

app.post("/scim/v2/Groups", async (req, res) => {
  try {
    const model = mapScimGroupToModel(req.body);
    const token = await getAdminToken();
    const group = await upsertGroup(token, model.name);

    for (const member of model.members) {
      const user = await findUserByUsername(token, member);
      if (user) {
        await addUserToGroup(token, user.id, group.id);
      }
    }

    res.status(201).json(scimGroupResponse(model, group.id));
  } catch (err) {
    if (isKeycloakError(err)) {
      scimKeycloakRequestFailuresTotal.inc({ operation: "create_group" });
    }
    res.status(400).json({ error: err.message });
  }
});

app.patch("/scim/v2/Groups/:id", async (req, res) => {
  try {
    const token = await getAdminToken();
    const operations = Array.isArray(req.body?.Operations) ? req.body.Operations : [];
    const members = [];

    for (const op of operations) {
      if (op.path === "members" && Array.isArray(op.value)) {
        for (const m of op.value) {
          if (m.value || m.display) members.push(m.value || m.display);
        }
      }
    }

    for (const member of members) {
      const user = await findUserByUsername(token, member);
      if (user) {
        await addUserToGroup(token, user.id, req.params.id);
      }
    }

    res.json({ schemas: ["urn:ietf:params:scim:schemas:core:2.0:Group"], id: req.params.id });
  } catch (err) {
    if (isKeycloakError(err)) {
      scimKeycloakRequestFailuresTotal.inc({ operation: "patch_group" });
    }
    res.status(400).json({ error: err.message });
  }
});

app.listen(port, () => {
  console.log(`scim-bridge listening on ${port}`);
});
