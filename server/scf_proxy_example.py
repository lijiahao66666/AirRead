# -*- coding: utf8 -*-
import json
import os
import sys
import traceback

# 尝试导入腾讯云 SDK
try:
    from tencentcloud.common import credential
    from tencentcloud.common.profile.client_profile import ClientProfile
    from tencentcloud.common.profile.http_profile import HttpProfile
    from tencentcloud.common.common_client import CommonClient
    from tencentcloud.common.exception.tencent_cloud_sdk_exception import TencentCloudSDKException
except ImportError:
    print("请先在 SCF 层或代码目录中安装 tencentcloud-sdk-python")

# ----------------------------------------------------------------------
# 配置区域
# ----------------------------------------------------------------------

# 1. 密钥配置
# 建议在 SCF 环境变量中配置 TENCENT_SECRET_ID 和 TENCENT_SECRET_KEY
SECRET_ID = os.environ.get("TENCENT_SECRET_ID", "")
SECRET_KEY = os.environ.get("TENCENT_SECRET_KEY", "")

# 2. 白名单配置
# 只有在此列表中的 Service 和 Action 才会被允许调用
ALLOWED_CONFIG = {
    # 机器翻译
    "tmt": {
        "host": "tmt.tencentcloudapi.com",
        "actions": ["TextTranslate"]
    },
    # 混元大模型 (问答/总结)
    "hunyuan": {
        "host": "hunyuan.tencentcloudapi.com",
        "actions": ["ChatCompletions"]
    },
    # 语音合成 (朗读)
    "tts": {
        "host": "tts.tencentcloudapi.com",
        "actions": ["TextToVoice", "CreateTtsTask"]
    },
    # [新增] AI 绘画 (插画)
    "aiart": {
        "host": "aiart.tencentcloudapi.com",
        "actions": ["SubmitTextToImageJob", "QueryTextToImageJob"]
    }
}

# ----------------------------------------------------------------------
# 主逻辑
# ----------------------------------------------------------------------

def main_handler(event, context):
    print("Received event:", json.dumps(event, ensure_ascii=False))

    # 1. 处理 API 网关的各种触发格式
    body_str = "{}"
    if "body" in event:
        body_str = event["body"]
        # 处理 Base64 编码 (如果是 API 网关触发)
        if event.get("isBase64Encoded", False):
            import base64
            try:
                body_str = base64.b64decode(body_str).decode("utf-8")
            except Exception:
                pass
    
    try:
        req_data = json.loads(body_str)
    except Exception:
        return _error_response(400, "Invalid JSON body")

    # 2. 提取参数
    service = req_data.get("service")
    action = req_data.get("action")
    version = req_data.get("version")
    region = req_data.get("region", "ap-guangzhou")
    payload = req_data.get("payload", {})
    
    # 3. 安全校验
    if not service or not action:
        return _error_response(400, "Missing service or action")

    if service not in ALLOWED_CONFIG:
        return _error_response(403, f"Service '{service}' is not allowed by proxy policy")
    
    svc_config = ALLOWED_CONFIG[service]
    if action not in svc_config["actions"]:
        return _error_response(403, f"Action '{action}' is not allowed by proxy policy")

    # 4. 检查密钥
    if not SECRET_ID or not SECRET_KEY:
        # 如果请求中自带了密钥（开发调试模式），可以使用（可选，视安全策略而定）
        # 这里仅演示使用环境变量密钥
        return _error_response(500, "Server configuration error: Missing credentials")

    # 5. 发起请求
    try:
        cred = credential.Credential(SECRET_ID, SECRET_KEY)
        http_profile = HttpProfile()
        http_profile.endpoint = svc_config["host"]
        
        client_profile = ClientProfile()
        client_profile.httpProfile = http_profile
        
        # 使用 CommonClient 调用任意云产品接口
        client = CommonClient(service, version, cred, region, client_profile)
        
        # 对于流式请求（如 ChatCompletions Stream=True），SCF 最好使用 Response Streaming 特性
        # 这里仅演示普通 JSON 响应的处理
        # 注意：CommonClient.call_json 内部会处理签名和网络请求
        resp = client.call_json(action, payload)
        
        # 6. 返回结果
        # 这里的 resp 已经是 Python 字典（如果是 json_format）或者 JSON 字符串
        # call_json 返回的是 bytes 类型的 JSON 字符串，或者 dict (取决于 SDK 版本)
        # 通常 SDK 返回的是 Response 结构体内的内容
        
        response_body = {
            "Response": resp.get("Response", resp) # 兼容不同 SDK 返回格式
        }
        
        return {
            "isBase64Encoded": False,
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json; charset=utf-8",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Headers": "*"
            },
            "body": json.dumps(response_body, ensure_ascii=False)
        }

    except TencentCloudSDKException as err:
        return _error_response(500, f"TencentCloud SDK Error: {err.message}", code=err.code)
    except Exception as e:
        traceback.print_exc()
        return _error_response(500, f"Internal Error: {str(e)}")

def _error_response(status, message, code="ProxyError"):
    return {
        "isBase64Encoded": False,
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json; charset=utf-8",
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps({
            "Response": {
                "Error": {
                    "Code": code,
                    "Message": message
                }
            }
        }, ensure_ascii=False)
    }
