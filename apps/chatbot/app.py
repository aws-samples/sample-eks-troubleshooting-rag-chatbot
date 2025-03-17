import gradio as gr
from logger import logger
from datetime import datetime
from embedder import encode_query
from retriever import retrieve_documents, construct_prompt
from kubernetes_resource import generate_response_with_kubectl

# Create the chatbot interface that will be called.
def chatbot_interface(user_input, model_choice, index_date):
    # Transform to the desired format YYYYMMDD
    formatted_date = index_date.strftime("%Y%m%d")
    index_name = f"eks-cluster-{formatted_date}"
    logger.info(f"Received user query for date: {index_date.strftime("%Y-%m-%d")}, model: {model_choice}, and user input: {user_input}")
    query_embedding = encode_query(user_input)

    retrieved_docs = retrieve_documents(query_embedding=query_embedding, index_name=index_name)

    prompt = construct_prompt(query=user_input, retrieved_docs=retrieved_docs)
    logger.info(f"Troubleshooting Prompt: {prompt}")
    
    # Choose the model based on the combo box selection
    if model_choice == "Claude":
        response = generate_response_with_kubectl(prompt, "claude")
    elif model_choice == "DeepSeek":
        response = generate_response_with_kubectl(prompt, "deepseek")
    else:
        response = "Invalid model selection"
        
    logger.info(f"Generated response: {response}")
    return response


def create_interface():
    with gr.Blocks(css=".container { max-width: 700px; margin: auto; padding-top: 20px; }") as demo:
        gr.Markdown(
            """
            <div style="text-align: center;">
                <h1>Document Retrieval Chatbot</h1>
            </div>
            """
        )

        with gr.Row():
            with gr.Column():
                index_date = gr.DateTime(
                    label="Select Date",
                    type="datetime",
                    include_time=False,
                    info="Select the date to query logs"
                )

                # Add the model selection combo box
                model_dropdown = gr.Dropdown(
                    choices=["Claude", "DeepSeek"],
                    value="Claude",
                    label="Select Model"
                )

                user_input = gr.Textbox(
                    label="Your Question",
                    placeholder="Type your question here..."
                )
                submit_button = gr.Button("Submit")

            with gr.Column():
                output = gr.Markdown(label="Response")

        submit_button.click(
            fn=chatbot_interface,
            inputs=[user_input, model_dropdown, index_date],
            outputs=output
        )

    return demo


if __name__ == "__main__":
    logger.info("Starting Gradio interface...")
    interface = create_interface()
    interface.launch()
    logger.info("Gradio interface launched successfully.")
    