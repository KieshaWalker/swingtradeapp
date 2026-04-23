import numpy as np


def _slope(values: list[float | None]) -> float | None:
    """OLS slope of non-None values over their indices."""
    pts = [(i, v) for i, v in enumerate(values) if v is not None]
    if len(pts) < 2:
        return None
    xs = np.array([p[0] for p in pts], dtype=float)
    ys = np.array([p[1] for p in pts], dtype=float)
    xs -= xs.mean()
    denom = float(np.dot(xs, xs))
    return float(np.dot(xs, ys) / denom) if denom else None
