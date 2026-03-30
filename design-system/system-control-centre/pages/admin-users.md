# Admin Users Page — Design Override

## Layout
- Page header: "Users" title + "Add User" button (right, primary, superadmin only)
- Search input below header (full width, placeholder "Search by name or email")
- User table:
  - Columns: Name, Email (mono), Status (dot badge), Superadmin (yes/no), Created, Actions
  - Status: green dot "Active" / red dot "Inactive"
  - Actions: View button (ghost)
  - Row click → user detail page

## User Detail Page
- Back button + User name as heading
- Info card: Name, Email, Status, Superadmin, Created
- Product Access table:
  - Columns: Product, Role, Permissions count, Actions
  - "Add Product Access" button above table
  - Each row: Remove button (danger ghost)
- Permission Overrides section:
  - Table: Permission, Type (GRANT badge green / DENY badge red), Product, Actions
  - "Add Override" button
  - Each row: Remove button
- "Deactivate User" button at bottom (danger variant, with confirmation dialog)

## Add User Dialog
- Fields: First Name, Last Name, Email, Password, Superadmin checkbox
- Simple form, no steps
- Validation: all required except superadmin

## Assign Role Dialog
- Product dropdown (lists from ProductSlug ADT)
- Role dropdown (Admin/Manager/Viewer/custom roles for selected product)
- Shows permission list below dropdown (read-only, shows what the role includes)
- Save button
