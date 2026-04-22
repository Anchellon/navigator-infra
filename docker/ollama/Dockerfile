FROM ollama/ollama:latest
RUN ollama serve & sleep 15 && ollama pull nomic-embed-text && pkill ollama
EXPOSE 11434
ENTRYPOINT ["ollama", "serve"]
