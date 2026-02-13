const kcHost = process.env.KC_HOSTNAME;
const kcInternalUrl = process.env.KC_INTERNAL_URL || "http://keycloak:8080";
const realm = process.env.KC_REALM || "master";
const adminUser = process.env.KC_ADMIN;
const adminPassword = process.env.KC_ADMIN_PASSWORD;

if (!kcHost || !adminUser || !adminPassword || !kcInternalUrl) {
  throw new Error("Missing KC_HOSTNAME/KC_INTERNAL_URL/KC_ADMIN/KC_ADMIN_PASSWORD");
}

const tokenUrl = `${kcInternalUrl}/realms/master/protocol/openid-connect/token`;
const adminBase = `${kcInternalUrl}/admin/realms/${realm}`;

async function getAdminToken() {
  const body = new URLSearchParams({
    grant_type: "password",
    client_id: "admin-cli",
    username: adminUser,
    password: adminPassword,
  });

  let res;
  try {
    res = await fetch(tokenUrl, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
  } catch (err) {
    throw new Error(`Keycloak token request failed: ${err.message}`);
  }

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Keycloak token error: ${res.status} ${text}`);
  }

  const json = await res.json();
  return json.access_token;
}

async function kcRequest(path, { method = "GET", token, body } = {}) {
  let res;
  try {
    res = await fetch(`${adminBase}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (err) {
    throw new Error(`Keycloak API request failed ${method} ${path}: ${err.message}`);
  }

  if (!res.ok && res.status !== 404) {
    const text = await res.text();
    throw new Error(`Keycloak API error ${method} ${path}: ${res.status} ${text}`);
  }

  return res;
}

async function findUserByUsername(token, username) {
  const res = await kcRequest(`/users?username=${encodeURIComponent(username)}&exact=true`, { token });
  const users = await res.json();
  return users[0] || null;
}

async function findUserById(token, id) {
  const res = await kcRequest(`/users/${id}`, { token });
  if (res.status === 404) return null;
  return res.json();
}

async function upsertUser(token, user) {
  const existing = await findUserByUsername(token, user.username);
  if (existing) {
    await kcRequest(`/users/${existing.id}`, {
      method: "PUT",
      token,
      body: {
        username: user.username,
        email: user.email,
        firstName: user.firstName,
        lastName: user.lastName,
        enabled: user.enabled,
        attributes: user.attributes || {},
      },
    });
    return { id: existing.id, created: false };
  }

  const createRes = await kcRequest(`/users`, {
    method: "POST",
    token,
    body: {
      username: user.username,
      email: user.email,
      firstName: user.firstName,
      lastName: user.lastName,
      enabled: user.enabled,
      emailVerified: true,
      attributes: user.attributes || {},
    },
  });

  const location = createRes.headers.get("location") || "";
  const id = location.split("/").pop();
  if (!id) {
    throw new Error("Failed to parse created user id from Keycloak location header");
  }

  return { id, created: true };
}

async function setUserPassword(token, userId, password) {
  await kcRequest(`/users/${userId}/reset-password`, {
    method: "PUT",
    token,
    body: {
      type: "password",
      value: password,
      temporary: false,
    },
  });
}

async function listGroups(token) {
  const res = await kcRequest(`/groups?max=200`, { token });
  return res.json();
}

async function ensureGroup(token, name) {
  const groups = await listGroups(token);
  const found = groups.find((g) => g.name === name);
  if (found) return found.id;

  await kcRequest(`/groups`, {
    method: "POST",
    token,
    body: { name },
  });

  const refreshed = await listGroups(token);
  const created = refreshed.find((g) => g.name === name);
  if (!created) {
    throw new Error(`Failed to create group ${name}`);
  }
  return created.id;
}

async function addUserToGroup(token, userId, groupId) {
  await kcRequest(`/users/${userId}/groups/${groupId}`, {
    method: "PUT",
    token,
  });
}

async function upsertGroup(token, name) {
  const id = await ensureGroup(token, name);
  return { id };
}

module.exports = {
  getAdminToken,
  findUserByUsername,
  findUserById,
  upsertUser,
  setUserPassword,
  ensureGroup,
  addUserToGroup,
  upsertGroup,
};
