FROM python:3.13-slim

WORKDIR /app

# Install uv for fast dependency management
RUN pip install --no-cache-dir uv

# Copy dependency files first for layer caching
COPY pyproject.toml uv.lock ./

# Install dependencies (prerelease allowed for preview SDK packages)
RUN uv sync --frozen --no-dev --prerelease=allow

# Copy application source
COPY . .

EXPOSE 3978

CMD ["uv", "run", "--no-sync", "python", "start.py"]
