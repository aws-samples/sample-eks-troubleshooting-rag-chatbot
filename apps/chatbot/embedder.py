import boto3
import json


def encode_query(query):
    # Initialize Bedrock client
    bedrock_runtime = boto3.client(
        service_name='bedrock-runtime'
    )

    # Call Bedrock to generate embedding
    response = bedrock_runtime.invoke_model(
        modelId="amazon.titan-embed-text-v2:0",
        contentType="application/json",
        accept="application/json",
        body=json.dumps({"inputText": query})
    )

    # Extract embedding from response
    embedding = json.loads(response.get('body').read())['embedding']

    return embedding
