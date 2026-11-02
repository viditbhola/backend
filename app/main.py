from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware

from app.core.config import get_settings
from app.core.limiter import limiter
from app.routers import budget, clients, dashboard, me, payments, projects, proposals

app = FastAPI(title="Project Payment Tracker")

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
app.add_middleware(SlowAPIMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=get_settings().allowed_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)

for router in (me.router, clients.router, projects.router, payments.router, budget.router, dashboard.router, proposals.router, projects.deletion_router):
    app.include_router(router)


@app.get("/health")
def health():
    return {"status": "ok"}
