enum AiChatModelChoice {
  onlineHunyuan,
  localHunyuan05b,
  localHunyuan18b,
}

extension AiChatModelChoiceX on AiChatModelChoice {
  bool get isOnline => this == AiChatModelChoice.onlineHunyuan;
  bool get isLocal => !isOnline;
}

