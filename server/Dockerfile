# Reading Sync server: docker build -t reading-sync server/
# docker run -d -p 8081:8081 -v reading-sync:/data -e KSYNC_ADMIN_PASSWORD=change-me reading-sync
FROM python:3.12-slim
WORKDIR /app
COPY kindle_sync_server.py .
ENV KSYNC_DATA=/data KSYNC_PORT=8081
VOLUME ["/data"]
EXPOSE 8081
CMD ["python3", "kindle_sync_server.py"]
