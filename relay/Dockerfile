# 基础镜像可用国内镜像仓覆盖，如: --build-arg PYTHON_IMAGE=docker.m.daocloud.io/library/python:3.12-slim
ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE}

WORKDIR /srv/relay
COPY requirements.txt .
# 依赖走国内 PyPI 镜像（可用 PIP_INDEX_URL 覆盖）
ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
RUN pip install --no-cache-dir -i ${PIP_INDEX_URL} -r requirements.txt
COPY . .

ENV RELAY_DB=/data/relay.db

EXPOSE 8000
CMD ["python", "main.py"]
