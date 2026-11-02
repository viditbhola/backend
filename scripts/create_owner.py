"""Create an owner account. Run once per owner (max 2 enforced by the database).

    python -m scripts.create_owner "Full Name" owner@example.com 'a-strong-password'

Reads SUPABASE_URL / SUPABASE_SERVICE_KEY from backend/.env.
"""

import sys

from app.core.supabase import get_supabase


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    full_name, email, password = sys.argv[1:4]
    db = get_supabase()
    created = db.auth.admin.create_user({"email": email, "password": password, "email_confirm": True})
    try:
        db.table("profiles").insert(
            {"id": created.user.id, "role": "owner", "full_name": full_name, "email": email}
        ).execute()
    except Exception:
        db.auth.admin.delete_user(created.user.id)
        raise
    print(f"Owner created: {email}")


if __name__ == "__main__":
    main()
