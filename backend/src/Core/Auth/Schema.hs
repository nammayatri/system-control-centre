{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

-- | Beam schema for RBAC/auth tables.
--
-- Canonical location for all core RBAC-owned Beam table definitions:
--
--  * 'ScPersonT'                    — sc_person
--  * 'ScRegistrationTokenT'         — sc_registration_token
--  * 'ScRoleT'                      — sc_role
--  * 'ScPersonProductAccessT'       — sc_person_product_access
--  * 'ScPersonDeploymentAccessT'    — sc_person_deployment_access
--  * 'ScPersonPermissionOverrideT'  — sc_person_permission_override
--  * 'ScAuditLogT'                  — sc_audit_log
--  * 'CoreDb'                       — Beam Database binding all eight tables
module Core.Auth.Schema where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import Data.Vector (Vector)
import Database.Beam

-- ── sc_person ──────────────────────────────────────────────────────

data ScPersonT f = ScPersonT
  { spId :: Columnar f UUID,
    spEmail :: Columnar f Text,
    spFirstName :: Columnar f Text,
    spLastName :: Columnar f Text,
    spPasswordHash :: Columnar f Text,
    spIsActive :: Columnar f Bool,
    spIsSuperadmin :: Columnar f Bool,
    spCreatedAt :: Columnar f UTCTime,
    spUpdatedAt :: Columnar f UTCTime
  }
  deriving (Generic, Beamable)

type ScPerson = ScPersonT Identity

deriving instance Show ScPerson

instance Table ScPersonT where
  data PrimaryKey ScPersonT f = ScPersonId (Columnar f UUID) deriving (Generic, Beamable)
  primaryKey = ScPersonId . spId

-- ── sc_registration_token ──────────────────────────────────────────

data ScRegistrationTokenT f = ScRegistrationTokenT
  { srtId :: Columnar f UUID,
    srtPersonId :: Columnar f UUID,
    srtToken :: Columnar f Text,
    srtIsActive :: Columnar f Bool,
    srtCreatedAt :: Columnar f UTCTime,
    srtExpiresAt :: Columnar f UTCTime
  }
  deriving (Generic, Beamable)

type ScRegistrationToken = ScRegistrationTokenT Identity

deriving instance Show ScRegistrationToken

instance Table ScRegistrationTokenT where
  data PrimaryKey ScRegistrationTokenT f = ScRegistrationTokenId (Columnar f UUID) deriving (Generic, Beamable)
  primaryKey = ScRegistrationTokenId . srtId

-- ── sc_role ────────────────────────────────────────────────────────

data ScRoleT f = ScRoleT
  { srId :: Columnar f UUID,
    srProductSlug :: Columnar f Text,
    srName :: Columnar f Text,
    srDescription :: Columnar f (Maybe Text),
    srIsSystemRole :: Columnar f Bool,
    srPermissions :: Columnar f (Maybe (Vector Text)),
    srCreatedAt :: Columnar f UTCTime
  }
  deriving (Generic, Beamable)

type ScRole = ScRoleT Identity

deriving instance Show ScRole

instance Table ScRoleT where
  data PrimaryKey ScRoleT f = ScRoleId (Columnar f UUID) deriving (Generic, Beamable)
  primaryKey = ScRoleId . srId

-- ── sc_person_product_access ───────────────────────────────────────

data ScPersonProductAccessT f = ScPersonProductAccessT
  { sppaId :: Columnar f UUID,
    sppaPersonId :: Columnar f UUID,
    sppaProductSlug :: Columnar f Text,
    sppaRoleId :: Columnar f UUID,
    sppaGrantedBy :: Columnar f (Maybe UUID),
    sppaCreatedAt :: Columnar f UTCTime
  }
  deriving (Generic, Beamable)

type ScPersonProductAccess = ScPersonProductAccessT Identity

deriving instance Show ScPersonProductAccess

instance Table ScPersonProductAccessT where
  data PrimaryKey ScPersonProductAccessT f = ScPersonProductAccessId (Columnar f UUID) deriving (Generic, Beamable)
  primaryKey = ScPersonProductAccessId . sppaId

-- ── sc_person_deployment_access ─────────────────────────────────────

data ScPersonDeploymentAccessT f = ScPersonDeploymentAccessT
  { spdaId :: Columnar f UUID,
    spdaPersonId :: Columnar f UUID,
    spdaProductSlug :: Columnar f Text,
    spdaAppGroup :: Columnar f Text,
    spdaRoleId :: Columnar f UUID,
    spdaGrantedBy :: Columnar f (Maybe UUID),
    spdaCreatedAt :: Columnar f UTCTime
  }
  deriving (Generic, Beamable)

type ScPersonDeploymentAccess = ScPersonDeploymentAccessT Identity

deriving instance Show ScPersonDeploymentAccess

instance Table ScPersonDeploymentAccessT where
  data PrimaryKey ScPersonDeploymentAccessT f = ScPersonDeploymentAccessId (Columnar f UUID) deriving (Generic, Beamable)
  primaryKey = ScPersonDeploymentAccessId . spdaId

-- ── sc_person_permission_override ──────────────────────────────────

data ScPersonPermissionOverrideT f = ScPersonPermissionOverrideT
  { sppoId :: Columnar f UUID,
    sppoPersonId :: Columnar f UUID,
    sppoProductSlug :: Columnar f Text,
    sppoPermissionAction :: Columnar f Text,
    sppoOverrideType :: Columnar f Text,
    sppoGrantedBy :: Columnar f (Maybe UUID),
    sppoCreatedAt :: Columnar f UTCTime
  }
  deriving (Generic, Beamable)

type ScPersonPermissionOverride = ScPersonPermissionOverrideT Identity

deriving instance Show ScPersonPermissionOverride

instance Table ScPersonPermissionOverrideT where
  data PrimaryKey ScPersonPermissionOverrideT f = ScPersonPermissionOverrideId (Columnar f UUID) deriving (Generic, Beamable)
  primaryKey = ScPersonPermissionOverrideId . sppoId

data McpPatKeyT f = McpPatKeyT
  { mpkId :: Columnar f UUID,
    mpkPersonId :: Columnar f UUID,
    mpkLabel :: Columnar f Text,
    mpkTokenPrefix :: Columnar f Text,
    mpkTokenHash :: Columnar f Text,
    mpkCreatedAt :: Columnar f UTCTime,
    mpkExpiresAt :: Columnar f UTCTime,
    mpkLastUsedAt :: Columnar f (Maybe UTCTime),
    mpkRevokedAt :: Columnar f (Maybe UTCTime)
  }
  deriving (Generic, Beamable)

type McpPatKey = McpPatKeyT Identity

deriving instance Show McpPatKey

instance Table McpPatKeyT where
  data PrimaryKey McpPatKeyT f = McpPatKeyId (Columnar f UUID) deriving (Generic, Beamable)
  primaryKey = McpPatKeyId . mpkId

-- ── sc_audit_log ───────────────────────────────────────────────────

data ScAuditLogT f = ScAuditLogT
  { salId :: Columnar f UUID,
    salPersonId :: Columnar f (Maybe UUID),
    salAction :: Columnar f Text,
    salEntityType :: Columnar f (Maybe Text),
    salEntityId :: Columnar f (Maybe Text),
    salDetails :: Columnar f (Maybe Value),
    salCreatedAt :: Columnar f UTCTime
  }
  deriving (Generic, Beamable)

type ScAuditLog = ScAuditLogT Identity

deriving instance Show ScAuditLog

instance Table ScAuditLogT where
  data PrimaryKey ScAuditLogT f = ScAuditLogId (Columnar f UUID) deriving (Generic, Beamable)
  primaryKey = ScAuditLogId . salId

-- ── CoreDb ─────────────────────────────────────────────────────────

data CoreDb f = CoreDb
  { scPerson :: f (TableEntity ScPersonT),
    scRegistrationToken :: f (TableEntity ScRegistrationTokenT),
    scRole :: f (TableEntity ScRoleT),
    scPersonProductAccess :: f (TableEntity ScPersonProductAccessT),
    scPersonDeploymentAccess :: f (TableEntity ScPersonDeploymentAccessT),
    scPersonPermissionOverride :: f (TableEntity ScPersonPermissionOverrideT),
    scAuditLog :: f (TableEntity ScAuditLogT),
    mcpPatKeys :: f (TableEntity McpPatKeyT)
  }
  deriving (Generic, Database be)

coreDb :: DatabaseSettings be CoreDb
coreDb =
  defaultDbSettings
    `withDbModification` dbModification
      { scPerson =
          setEntityName "sc_person"
            <> modifyTableFields
              tableModification
                { spId = fieldNamed "id",
                  spEmail = fieldNamed "email",
                  spFirstName = fieldNamed "first_name",
                  spLastName = fieldNamed "last_name",
                  spPasswordHash = fieldNamed "password_hash",
                  spIsActive = fieldNamed "is_active",
                  spIsSuperadmin = fieldNamed "is_superadmin",
                  spCreatedAt = fieldNamed "created_at",
                  spUpdatedAt = fieldNamed "updated_at"
                },
        scRegistrationToken =
          setEntityName "sc_registration_token"
            <> modifyTableFields
              tableModification
                { srtId = fieldNamed "id",
                  srtPersonId = fieldNamed "person_id",
                  srtToken = fieldNamed "token",
                  srtIsActive = fieldNamed "is_active",
                  srtCreatedAt = fieldNamed "created_at",
                  srtExpiresAt = fieldNamed "expires_at"
                },
        scRole =
          setEntityName "sc_role"
            <> modifyTableFields
              tableModification
                { srId = fieldNamed "id",
                  srProductSlug = fieldNamed "product_slug",
                  srName = fieldNamed "name",
                  srDescription = fieldNamed "description",
                  srIsSystemRole = fieldNamed "is_system_role",
                  srPermissions = fieldNamed "permissions",
                  srCreatedAt = fieldNamed "created_at"
                },
        scPersonProductAccess =
          setEntityName "sc_person_product_access"
            <> modifyTableFields
              tableModification
                { sppaId = fieldNamed "id",
                  sppaPersonId = fieldNamed "person_id",
                  sppaProductSlug = fieldNamed "product_slug",
                  sppaRoleId = fieldNamed "role_id",
                  sppaGrantedBy = fieldNamed "granted_by",
                  sppaCreatedAt = fieldNamed "created_at"
                },
        scPersonDeploymentAccess =
          setEntityName "sc_person_deployment_access"
            <> modifyTableFields
              tableModification
                { spdaId = fieldNamed "id",
                  spdaPersonId = fieldNamed "person_id",
                  spdaProductSlug = fieldNamed "product_slug",
                  spdaAppGroup = fieldNamed "app_group",
                  spdaRoleId = fieldNamed "role_id",
                  spdaGrantedBy = fieldNamed "granted_by",
                  spdaCreatedAt = fieldNamed "created_at"
                },
        scPersonPermissionOverride =
          setEntityName "sc_person_permission_override"
            <> modifyTableFields
              tableModification
                { sppoId = fieldNamed "id",
                  sppoPersonId = fieldNamed "person_id",
                  sppoProductSlug = fieldNamed "product_slug",
                  sppoPermissionAction = fieldNamed "permission_action",
                  sppoOverrideType = fieldNamed "override_type",
                  sppoGrantedBy = fieldNamed "granted_by",
                  sppoCreatedAt = fieldNamed "created_at"
                },
        scAuditLog =
          setEntityName "sc_audit_log"
            <> modifyTableFields
              tableModification
                { salId = fieldNamed "id",
                  salPersonId = fieldNamed "person_id",
                  salAction = fieldNamed "action",
                  salEntityType = fieldNamed "entity_type",
                  salEntityId = fieldNamed "entity_id",
                  salDetails = fieldNamed "details",
                  salCreatedAt = fieldNamed "created_at"
                },
        mcpPatKeys =
          setEntityName "mcp_pat_keys"
            <> modifyTableFields
              tableModification
                { mpkId = fieldNamed "id",
                  mpkPersonId = fieldNamed "person_id",
                  mpkLabel = fieldNamed "label",
                  mpkTokenPrefix = fieldNamed "token_prefix",
                  mpkTokenHash = fieldNamed "token_hash",
                  mpkCreatedAt = fieldNamed "created_at",
                  mpkExpiresAt = fieldNamed "expires_at",
                  mpkLastUsedAt = fieldNamed "last_used_at",
                  mpkRevokedAt = fieldNamed "revoked_at"
                }
      }
