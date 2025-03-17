import boto3
import json
import requests
import os
from logger import logger

def invoke_claude(prompt_text):
    """
    Invokes the Claude model via Bedrock with the given prompt text.
    
    :param prompt_text: The input prompt for the model.
    :return: The response from the Claude model.
    """
    # Initialize the Bedrock client
    bedrock_client = boto3.client(service_name='bedrock-runtime')

    # Define the request body for the Claude model
    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 1000,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": prompt_text
                    }
                ]
            }
        ]
    }

    # Invoke the Claude model through the Bedrock API
    response = bedrock_client.invoke_model(
        modelId='anthropic.claude-3-sonnet-20240229-v1:0',
        contentType='application/json',
        accept='application/json',
        body=json.dumps(body)
    )
    
    # Parse the model's response
    response_body = json.loads(response['body'].read())
    response_text = response_body['content'][0]['text']
    
    return response_text

def invoke_deepseek_vllm(prompt_text):
    url = os.getenv("VLLM_ENDPOINT", "http://localhost:8081")
    url_complete = f"{url}/v1/chat/completions"
    
    headers = {
        "Content-Type": "application/json"
    }
    
    payload = {
        "model": "deepseek-ai/DeepSeek-R1-Distill-Llama-8B",
        "messages": [
            {
                "role": "user",
                "content": prompt_text
            }
        ]
    }

    try:
        response = requests.post(url_complete, headers=headers, json=payload)
        
        # Log detailed debug information
        logger.debug(f"Request URL: {url_complete}")
        logger.debug(f"Request Headers: {headers}")
        logger.debug(f"Request Payload: {json.dumps(payload, indent=2)}")
        logger.debug(f"Response Status Code: {response.status_code}")
        logger.debug(f"Response Headers: {dict(response.headers)}")
        
        try:
            logger.info(f"Response Body: {response.text}")
        except:
            logger.error("Could not print response body")

        response.raise_for_status()
        
        result = response.json()
        
        if "choices" in result and len(result["choices"]) > 0:
            return result["choices"][0]["message"]["content"]
        else:
            return "No response content found"

    except requests.exceptions.RequestException as e:
        error_msg = f"Error making request to vLLM: {str(e)}"
        if hasattr(e.response, 'text'):
            error_msg += f"\nResponse body: {e.response.text}"
        logger.error(error_msg)
        return f"Error: {str(e)}"
    except json.JSONDecodeError as e:
        logger.error(f"Error decoding JSON response: {str(e)}")
        return f"Error decoding response: {str(e)}"
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}")
        return f"Unexpected error: {str(e)}"


    