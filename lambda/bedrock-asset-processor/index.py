import json

def handler(event, context):
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = event['Records'][0]['s3']['object']['key']
    print(f"Image received: {key}")
    return {
        'statusCode': 200,
        'body': json.dumps(f'Successfully processed {key}')
    }