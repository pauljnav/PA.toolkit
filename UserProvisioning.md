# User Provisioning — Power Automate Plan

## Onboarding request

The provisioning request is supplied by email using a fixed template:

User:       joe.bloggs@contoso.com
BU:         Operations
Teams:      Portal Users
Security:   Portal User
Web Roles:  Customer
Groups:     Operations
Categories: Clinical

The values identify the desired PROD configuration. The flow validates the requested configuration before making any changes.

---

## PROD provisioning

### 1. Provision the Dataverse user

* Add the Entra ID user to the **PROD Dataverse environment**.
* Confirm that the user exists as a Dataverse **System User**.
* If the user already exists, do not recreate them.

### 2. Configure the Dataverse user

Assign:

* **1 × Business Unit**
* **1 × or more Security Roles**
* **1 × or more Teams**

The initial version should use the values explicitly supplied in the onboarding request.

### 3. Configure the Power Pages Contact

* Locate the user's existing **Power Pages Contact**.
* Do not create a duplicate Contact if one already exists.
* Assign:

  * **1 × or more Web Roles**
  * **1 × or more Portal Groups**
  * **1 × or more Portal Categories**

---

# Flow architecture

```text
Onboarding Email
       │
       ▼
     Parse
       │
       ▼
   Validate Request
       │
       ├── User
       ├── BU
       ├── Team(s)
       ├── Security Role(s)
       ├── Contact
       ├── Web Role(s)
       ├── Portal Group(s)
       └── Portal Category(s)
       │
       ▼
    DRY RUN
       │
       ▼
Provisioning Plan
       │
       ▼
     Approval
       │
       ▼
     Execute
       │
       ▼
     Verify
       │
       ▼
Report Result
```

---

# Validation

Before changing PROD, validate that all requested objects exist and are usable:

* Entra ID user
* Dataverse environment
* Business Unit
* Security Role(s)
* Team(s)
* Power Pages Contact
* Web Role(s)
* Portal Group(s)
* Portal Category(s)

If validation fails, **make no changes** and report the problem.

Example:

```text
PROVISIONING BLOCKED

User:       joe.bloggs@company.ie
BU:         Operations        ✓
Team:       Portal Users      ✓
Security:   Portal User       ✓
Contact:    Found             ✓
Web Role:   Customer           ✓
Group:      Operations         ✓
Category:   Clinical           ✗ NOT FOUND

No changes were made to PROD.
```

---

# Dry-run

The flow generates a provisioning plan before making changes.

Example:

```text
PROVISIONING PLAN

User: joe.bloggs@company.ie

Dataverse
  ✓ User exists
  ✓ BU: Operations
  + Add Team: Portal Users
  + Assign Security Role: Portal User

Power Pages
  ✓ Contact found
  + Add Web Role: Customer
  + Add Portal Group: Operations
  + Add Portal Category: Clinical

No changes have been made.
```

The request can then be approved for execution.

---

# Execution

Use **native Power Automate / Dataverse actions wherever possible**.

Use the **Dataverse Web API only where a required operation is not exposed adequately through the standard connector actions**.

Conceptually:

```text
Native Dataverse action
        │
        ├── available → use it
        │
        └── unavailable/inadequate
                    │
                    ▼
             Dataverse Web API
```

This keeps the flow simpler and avoids unnecessary HTTP/API complexity.

---

# Verification

After provisioning, independently verify the resulting configuration.

Check:

```text
Dataverse User
 ├── Business Unit       ✓
 ├── Security Role(s)    ✓
 └── Team(s)             ✓

Power Pages Contact
 ├── Web Role(s)         ✓
 ├── Portal Group(s)     ✓
 └── Portal Category(s)  ✓
```

The final response should distinguish:

* **Provisioned successfully**
* **Already configured**
* **Provisioned with changes**
* **Failed**
* **Blocked during validation**

---

# Idempotency

Running the same request twice must not create duplicate relationships.

For every assignment:

```text
Does relationship already exist?
       │
   ┌───┴───┐
  YES      NO
   │        │
  Skip     Add
```

This allows the flow to safely retry after a transient failure.

---

# Future enhancement — Team → Business Unit mapping

Later, remove the need to explicitly supply the BU when it can be reliably derived from the user's primary team.

Maintain a controlled mapping:

```text
Team                  Business Unit
──────────────────    ──────────────
Portal Users          Operations
Clinical Users        Clinical
Admin Users           Administration
```

The flow could then:

```text
Primary Team
     │
     ▼
Team → BU mapping
     │
     ▼
Determine BU
```

The initial version should **not infer access assignments**. It should use the explicit onboarding request.

---

# Result

The finished process becomes:

```text
Email
  ↓
Parse
  ↓
Validate
  ↓
Generate provisioning plan
  ↓
Approval
  ↓
Provision PROD
  ↓
Verify
  ↓
Confirmation / failure report
```

The email is therefore a **declarative provisioning request**:

> Make this user's PROD configuration match these specified values.

The flow, rather than the requester, performs the individual Dataverse and Power Pages configuration operations.
