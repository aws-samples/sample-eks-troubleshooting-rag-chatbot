FROM public.ecr.aws/docker/library/python:3.13.2-slim

# Set working directory
WORKDIR /app

# Install necessary packages and kubectl
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/

# Copy requirements first to leverage Docker cache
COPY ./requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application code
COPY ./*.* .

# Expose the Gradio port
EXPOSE 7860

# Command to run the application
CMD ["python", "app.py"]
