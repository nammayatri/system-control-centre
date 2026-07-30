// Re-export admin functions from auth service
export {
  fetchUsers,
  fetchUser,
  createUser,
  updateUser,
  deactivateUser,
  assignRole,
  revokeProductAccess,
  assignDeploymentRole,
  revokeDeploymentAccess,
  fetchDeploymentAccessRoster,
  fetchProductAccessRoster,
  addPermissionOverride,
  removePermissionOverride,
  fetchAdminProducts,
  fetchProductPermissions,
  fetchProductRoles,
  createRole,
  updateRole,
} from '../auth/api';

export type { DeploymentRosterEntry, ProductRosterEntry } from '../auth/api';
