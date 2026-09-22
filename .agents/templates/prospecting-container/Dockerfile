# syntax=docker/dockerfile:1
FROM python:3.12-slim

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin prospecting
WORKDIR /app
COPY .agents/scripts/ /app/scripts/
COPY .agents/templates/prospecting-workbench/ /app/workbench/
RUN chown -R prospecting:prospecting /app

USER prospecting
EXPOSE 8765
ENTRYPOINT ["python3", "/app/scripts/prospecting-service-helper.py"]
CMD ["--store", "/data", "serve", "--bind", "127.0.0.1", "--port", "8765", "--ui-dir", "/app/workbench"]
