import base64
import json
import logging
import boto3
from opensearchpy import OpenSearch, RequestsHttpConnection, helpers
from requests_aws4auth import AWS4Auth
from datetime import datetime
import os

# Set up logging
logging.basicConfig(format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Get configuration from environment variables
opensearch_endpoint = os.environ.get('OPENSEARCH_ENDPOINT').replace('https://', '')
region = os.environ.get('AWS_REGION')
model = os.environ.get('EMBEDDING_MODEL')


# Initialize clients
bedrock_runtime = boto3.client(
    service_name='bedrock-runtime',
    region_name=region
)

credentials = boto3.Session().get_credentials()
auth = AWS4Auth(
    credentials.access_key,
    credentials.secret_key,
    region,
    'aoss',
    session_token=credentials.token
)

client = OpenSearch(
    hosts=[{'host': opensearch_endpoint, 'port': 443}],
    http_auth=auth,
    use_ssl=True,
    verify_certs=True,
    connection_class=RequestsHttpConnection
)


def get_embedding(text):
    """Generate embedding using Amazon Titan Embeddings V2 model"""
    try:
        body = json.dumps({
            "inputText": text
        })

        response = bedrock_runtime.invoke_model(
            modelId=model,
            contentType="application/json",
            accept="application/json",
            body=body
        )

        response_body = json.loads(response.get('body').read())
        return response_body.get('embedding')
    except Exception as e:
        logger.error(f"Error generating embedding: {str(e)}")
        raise


def encode_data(data):
    try:
        logger.info(f"Encoding {len(data)} items")
        embeddings = []
        for record in data:
            d = base64.b64decode(record['kinesis']['data']).decode('utf-8')
            embedding = get_embedding(str(d))
            embeddings.append({"log": str(d), "embedding": embedding})
        return embeddings
    except Exception as e:
        logger.error(f"Error while embedding data: {e}")
        raise


def index_data(embeddings, index_name):
    if not index_exists(index_name):
        create_index(index_name)

    bulk_data = []
    for i, embedding in enumerate(embeddings):
        bulk_data.append({
            "_index": index_name,
            "_source": {
                "embedding": embedding["embedding"],
                "log": embedding["log"],
                "id": i
            }
        })
    try:
        success, failed = helpers.bulk(
            client,
            bulk_data,
            raise_on_error=True,
            request_timeout=60,
        )
        logger.info(f"Indexed {success} documents" + (f", {len(failed)} failed" if failed else ""))

    except Exception as e:
        logger.error(f"Error during bulk indexing: {e}")
        raise


def index_exists(index_name):
    try:
        return client.indices.exists(index=index_name)
    except Exception as e:
        logger.error(f"Error checking index existence: {e}")
        return False


def create_index(index_name):
    logger.info(f"Creating index: {index_name}")
    body = {
        "settings": {
            "index": {
                "knn": True,
                "knn.algo_param.ef_search": 100
            }
        },
        "mappings": {
            "properties": {
                "embedding": {
                    "type": "knn_vector",
                    "dimension": 1024,
                    "method": {
                        "name": "hnsw",
                        "space_type": "l2",
                        "engine": "faiss",
                        "parameters": {
                            "ef_construction": 128,
                            "m": 24
                        }
                    }
                },
                "log": {
                    "type": "text"
                },
                "id": {
                    "type": "keyword"
                }
            }
        }
    }

    try:
        response = client.indices.create(index=index_name, body=body)
        if not response.get('acknowledged', False):
            logger.error(f"Failed to create index: {response}")
    except Exception as e:
        logger.error(f"Error creating index: {e}")
        raise


def handler(event, context):
    """Lambda function handler"""
    start_time = datetime.now()
    record_count = len(event['Records'])
    logger.info(f"Processing {record_count} records")

    try:
        timestamp = datetime.now().strftime("%Y%m%d")
        index_name = f"eks-cluster-{timestamp}"
        embeddings = encode_data(data=event['Records'])
        index_data(embeddings, index_name)

    except json.JSONDecodeError as e:
        logger.error(f"JSON parsing error: {str(e)}")
    except Exception as e:
        logger.error(f"Processing error: {str(e)}")

    duration = (datetime.now() - start_time).total_seconds()

    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': f'Processed {record_count} records',
            'requestId': context.aws_request_id,
            'executionTime': duration
        })
    }
