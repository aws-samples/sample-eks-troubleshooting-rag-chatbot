# Use AWS Lambda Python runtime as base image
FROM public.ecr.aws/lambda/python:3.11

# Copy requirements file
COPY requirements.txt ${LAMBDA_TASK_ROOT}

# Install dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy function code
COPY processor.py ${LAMBDA_TASK_ROOT}

# Set the CMD to your handler
CMD [ "processor.handler" ]
