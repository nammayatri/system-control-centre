// Re-export admin functions from auth service
export {
  fetchUsers,
  fetchUser,
  createUser,
  updateUser,
  deactivateUser,
  addProductAccess,
  removeProductAccess,
  addPermissionOverride,
  removePermissionOverride,
  fetchRoles,
  fetchRole,
  updateRole,
  fetchAdminProducts,
} from '../auth/api';
