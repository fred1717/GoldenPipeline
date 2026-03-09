Activate the virtual environment:  
The command below creates a self-contained Python environment:
- a `venv/` folder containing its own copy of the Python interpreter
- `pip` (Python's package manager - the tool that downloads and installs third-party libraries)
- and empty `lib/` directory for packages.  
This keeps project dependencies isolated from the system Python.
```bash
python3 -m venv venv
```

The next command, see below, modifies the current shell session, so that:
- `python` and `pip` point to the copies inside `venv/`, instead of the system-wide ones.
- any packages installed with `pip install` after activation go into `venv/lib/`, rather than the global Python.
```bash
source venv/bin/activate
```

The command below will now install the one dependency needed, i.e. the SDK for Python.  
The project's Lambda functions will use it for DynamoDB and Bedrock calls.  
Locally, it is needed to develop against the same interfaces:
The boto3 API — meaning the Python functions used to talk to AWS services (), like:
- boto3.client('dynamodb').put_item(...)
- boto3.client('bedrock-runtime').invoke_model(...)  

The Lambda functions that will eventually run on AWS will use these exact same function calls.  
By installing `boto3` locally, the code can be written, tested, and debugged in PyCharm now — then deployed to Lambda later without changing a single line.  
- function signatures
- parameter names
- response formats
These are identical, whether the code runs on a laptop or inside a Lambda.
```bash
pip install boto3
```
