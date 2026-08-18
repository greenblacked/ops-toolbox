# Test runner image — Python + RouterOS-api + pytest.
# Building this in a container removes any host-Python dependency (pyenv, pip, etc).
FROM python:3.12-alpine3.21

RUN apk add --no-cache bash

WORKDIR /opt/tester

COPY requirements.txt /opt/tester/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

COPY tester/entrypoint.sh /opt/tester/entrypoint.sh
RUN chmod +x /opt/tester/entrypoint.sh

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONPATH=/repo
ENV PYTEST_CACHE_DIR=/tmp/.pytest_cache

WORKDIR /repo

ENTRYPOINT ["/opt/tester/entrypoint.sh"]
CMD ["-v"]
