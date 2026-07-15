from strands import Agent, tool
from src.agents.k8s_specialist import K8sSpecialist
from src.config.settings import Config
from src.config.telemetry import setup_langfuse_telemetry
from src.prompts import ORCHESTRATOR_SYSTEM_PROMPT, CLASSIFICATION_PROMPT, K8S_KEYWORDS
from strands_tools.a2a_client import A2AClientToolProvider
from strands.hooks.events import BeforeInvocationEvent
import json
import boto3
import logging

logger = logging.getLogger(__name__)

# Initialize telemetry if enabled
setup_langfuse_telemetry()

class AgentSilentException(Exception):
    """Exception that should not generate error responses."""
    pass

class OrchestratorAgent:
    """Direct K8s troubleshooting orchestrator."""
    
    def __init__(self):
        self.k8s_specialist = K8sSpecialist()
        self.last_user_message = None
        
        try:
            self.bedrock_client = boto3.client('bedrock-runtime', region_name=Config.AWS_REGION)
        except Exception as e:
            logger.warning(f"Failed to initialize Bedrock client, falling back to keywords: {e}")
            self.bedrock_client = None
            
        self.agent = Agent(
            name="K8s Orchestrator",
            system_prompt=ORCHESTRATOR_SYSTEM_PROMPT,
            model=Config.BEDROCK_MODEL_ID,
            tools=[self.troubleshoot_k8s, self.memory_agent_provider]
        )
        
        self.agent.hooks.add_callback(BeforeInvocationEvent, self.callback_message_validator)
    
    def callback_message_validator(self, event: BeforeInvocationEvent):
        """Validate message before agent invocation."""
        classification = self._classify_with_nova(self.last_user_message)
        logger.info(f"Message classification: {classification}")
        
        if not classification:
            raise AgentSilentException("Agent decided not to respond to this message")

        return classification

    def _classify_with_nova(self, message: str) -> bool:
        """Use Amazon Nova Micro to classify if message is K8s/troubleshooting related."""
        try:
            prompt = CLASSIFICATION_PROMPT.format(message=message)
            
            body = {
                "messages": [
                    {
                        "role": "user",
                        "content": [{"text": prompt}]
                    }
                ],
                "inferenceConfig": {
                    "maxTokens": 10,
                    "temperature": 0.1
                }
            }
            
            response = self.bedrock_client.invoke_model(
                modelId=Config.CLASSIFICATION_MODEL_ID,
                body=json.dumps(body)
            )
            
            result = json.loads(response['body'].read())
            logger.info(f"Message classification should respond:{result}")
            
            answer = result['output']['message']['content'][0]['text'].strip().upper()
            
            return answer == "YES"
            
        except Exception as e:
            logger.error(f"Nova classification failed: {e}")
            logger.warning("Falling back to keyword-based classification")
            # Fallback to keyword matching
            return any(keyword in message.lower() for keyword in K8S_KEYWORDS)
        
    @tool
    def troubleshoot_k8s(self, query: str) -> str:
        """Perform K8s troubleshooting."""
        try:
            return self.k8s_specialist.troubleshoot(query)
        except Exception as e:
            return f"Troubleshooting error: {e}"
    
    @tool
    def memory_agent_provider(self, request: str) -> str:
        """Handle Memory agent connection using a2aclienttoolprovider
        
        Args:
            request (str): The request to send to the memory agent
            
        Returns:
            str: Response from the memory agent
            
        Raises:
            Exception: If memory agent connection fails
        """
        try:
            # Initialize provider with memory agent URL
            provider = A2AClientToolProvider(known_agent_urls=[Config.MEMORY_AGENT_SERVER_URL])
            logger.debug(f"Initialized memory agent provider: {provider}")
            
            # Get available tools from provider
            tools = provider.tools
            logger.debug(f"Available memory agent tools: {tools}")        
            
            # Create agent with tools and system prompt
            agent = Agent(
                tools=tools,
                system_prompt="You are a memory agent interface. Discover agents and tools you can use"
            )
            
            # Send request and get response
            response = agent(request)
            logger.info(f"Memory agent response received for request: {request[:100]}...")
            
            return str(response)
            
        except Exception as e:
            logger.error(f"Memory agent operation failed: {e}")
            raise Exception(f"Failed to process memory agent request: {str(e)}")