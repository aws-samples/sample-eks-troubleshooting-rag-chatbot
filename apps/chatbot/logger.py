import logging
import os

# Get the log level from the environment variable or default to DEBUG
log_level = os.getenv('LOG_LEVEL', 'INFO').upper()

# Configure the logger
logger = logging.getLogger("logger")
logger.setLevel(log_level)  # Set log level from the environment variable

# Create a console handler to output logs to the console
console_handler = logging.StreamHandler()

# Create a formatter and set it for the handler
formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
console_handler.setFormatter(formatter)

# Add the handler to the logger
logger.addHandler(console_handler)

