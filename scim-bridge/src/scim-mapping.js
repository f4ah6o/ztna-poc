function mapScimUserToKeycloak(payload) {
  if (!payload || !payload.userName) {
    throw new Error("SCIM userName is required");
  }

  const primaryEmail = Array.isArray(payload.emails)
    ? (payload.emails.find((e) => e.primary)?.value || payload.emails[0]?.value)
    : undefined;

  const groups = Array.isArray(payload.groups)
    ? payload.groups
        .map((g) => g.display || g.value)
        .filter(Boolean)
    : [];

  return {
    username: payload.userName,
    email: primaryEmail,
    firstName: payload.name?.givenName,
    lastName: payload.name?.familyName,
    enabled: payload.active !== false,
    password: payload.password,
    groups,
    attributes: {
      scim_external_id: payload.externalId ? [String(payload.externalId)] : [],
    },
  };
}

function mapScimGroupToModel(payload) {
  if (!payload || !payload.displayName) {
    throw new Error("SCIM group displayName is required");
  }

  const members = Array.isArray(payload.members)
    ? payload.members.map((m) => m.value || m.display).filter(Boolean)
    : [];

  return {
    name: payload.displayName,
    members,
  };
}

function scimUserResponse(user, id) {
  return {
    schemas: ["urn:ietf:params:scim:schemas:core:2.0:User"],
    id,
    userName: user.username,
    active: user.enabled,
    emails: user.email ? [{ value: user.email, primary: true }] : [],
    name: {
      givenName: user.firstName || "",
      familyName: user.lastName || "",
    },
  };
}

function scimGroupResponse(group, id) {
  return {
    schemas: ["urn:ietf:params:scim:schemas:core:2.0:Group"],
    id,
    displayName: group.name,
  };
}

module.exports = {
  mapScimUserToKeycloak,
  mapScimGroupToModel,
  scimUserResponse,
  scimGroupResponse,
};
