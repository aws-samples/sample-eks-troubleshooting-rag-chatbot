from datetime import datetime
from logger import logger
import pytz
from opensearchpy import OpenSearch, RequestsHttpConnection
from requests_aws4auth import AWS4Auth
import boto3
import os

# Define UTC timezone
utc = pytz.utc
opensearch_endpoint = os.environ.get('OPENSEARCH_ENDPOINT')

# Get credentials
credentials = boto3.Session().get_credentials()
region = 'us-east-1'

# Create AWS4Auth instance
auth = AWS4Auth(
    credentials.access_key,
    credentials.secret_key,
    region,
    'aoss',
    session_token=credentials.token  # Include this if you're using temporary credentials
)

# Configure OpenSearch client
client = OpenSearch(
    hosts=[{'host': opensearch_endpoint, 'port': 443}],
    http_auth=auth,
    use_ssl=True,
    verify_certs=True,
    connection_class=RequestsHttpConnection
)

def retrieve_documents(query_embedding, index_name, top_k=5, min_score=0.4):
    # Perform the search using the query embedding
    query_body = {
        "query": {
            "bool": {
                "must": [
                    {
                        "knn": {
                            "embedding": {
                                "vector": query_embedding,
                                "k": top_k
                            }
                        }
                    }
                ]
            }
        },
        "_source": False,
        "fields": ["id", "log"],
        "size": top_k,
        "min_score": min_score
    }

    results = client.search(
        body=query_body,
        index=index_name
    )

    if results["hits"]["total"]["value"] > 0:
        docs = [hit["fields"]["log"][0] for hit in results["hits"]["hits"]]
        return docs
    else:
        logger.error("No match for the prompt found in the vector database")


def construct_prompt(query, retrieved_docs):
    # Limit the number of documents in the context to max_docs

    if not retrieved_docs:
        context = "No relevant logs found."
    else:
        context = "\n\n".join(retrieved_docs)

    # Create a prompt to generate a kubectl command to get more details if needed 
    kubectl_prompt = "When needed Generate a kubectl command to get more details about the relevant logs, use a key 'KUBECTL_COMMAND: command' if true for to parse, make sure that you have real pod names not templates"
    # Construct the final prompt
    prompt = f"Instructions: {kubectl_prompt} \n\nUser Query: {query} \n\nContext:\n{context}\n\nResponse:"
    return prompt
