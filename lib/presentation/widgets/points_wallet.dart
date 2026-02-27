import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/config/auth_service.dart';
import '../../ai/config/checkin_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_tokens.dart';
import '../pages/auth/login_page.dart';
import '../providers/ai_model_provider.dart';

class PointsWallet extends StatefulWidget {
  final bool isDark;
  final Color textColor;
  final Color cardBg;
  final String? hintText;

  const PointsWallet({
    super.key,
    required this.isDark,
    required this.textColor,
    required this.cardBg,
    this.hintText,
  });

  @override
  State<PointsWallet> createState() => _PointsWalletState();
}

class _PointsWalletState extends State<PointsWallet> {
  bool _checkedInToday = false;
  bool _checkinBusy = false;
  int _streak = 0;

  @override
  void initState() {
    super.initState();
    _loadCheckinState();
  }

  Future<void> _loadCheckinState() async {
    final done = await CheckinService.hasCheckedInToday();
    final streak = await CheckinService.getStreak();
    if (mounted) {
      setState(() {
        _checkedInToday = done;
        _streak = streak;
      });
    }
  }

  Future<void> _doCheckin(AiModelProvider aiModel, StateSetter setSheetState) async {
    if (_checkedInToday || _checkinBusy) return;
    setSheetState(() => _checkinBusy = true);
    try {
      final result = await CheckinService.checkin();
      if (result.balance != null) {
        await aiModel.setPointsBalance(result.balance!);
      } else if (result.points > 0) {
        await aiModel.addPoints(result.points);
      }
      final streak = await CheckinService.getStreak();
      if (mounted) {
        setState(() {
          _checkedInToday = true;
          _streak = streak;
        });
        setSheetState(() {
          _checkedInToday = true;
          _streak = streak;
        });
      }
    } catch (e) {
      debugPrint('[PointsWallet] checkin error: $e');
    } finally {
      if (mounted) setSheetState(() => _checkinBusy = false);
    }
  }

  // ── Wallet BottomSheet ──────────────────────────────────────────

  void _showWalletSheet(AiModelProvider aiModel) {
    final isDark = widget.isDark;
    final textColor = widget.textColor;
    final sheetBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final sectionBg = isDark ? const Color(0xFF262626) : const Color(0xFFF7F7F7);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final checkinEnabled = CheckinService.isEnabled;
            final checkinPoints = CheckinService.rewardPoints;
            // TODO: 广告SDK接入后读取 RemoteConfigService.adEnabled
            // TODO: 微信支付接入后读取 RemoteConfigService.purchaseEnabled

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      // ── Title row ──
                      Row(
                        children: [
                          Text(
                            '积分钱包',
                            style: TextStyle(
                              color: textColor,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '余额：${aiModel.pointsBalance}',
                            style: TextStyle(
                              color: textColor.withOpacityCompat(0.7),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // ── Section: Account ──
                      _sectionCard(
                        sectionBg: sectionBg,
                        textColor: textColor,
                        child: Row(
                          children: [
                            Icon(
                              AuthService.isLoggedIn
                                  ? Icons.account_circle_rounded
                                  : Icons.account_circle_outlined,
                              color: AuthService.isLoggedIn
                                  ? Colors.green
                                  : textColor.withOpacityCompat(0.5),
                              size: 28,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    AuthService.isLoggedIn
                                        ? AuthService.phone
                                        : '未登录',
                                    style: TextStyle(
                                      color: textColor,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    AuthService.isLoggedIn
                                        ? '积分跨设备同步'
                                        : '登录后积分跨设备同步',
                                    style: TextStyle(
                                      color: textColor.withOpacityCompat(0.55),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              height: 32,
                              child: TextButton(
                                onPressed: () async {
                                  if (AuthService.isLoggedIn) {
                                    final confirm = await showDialog<bool>(
                                      context: sheetContext,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('退出登录'),
                                        content: const Text('退出后在线功能将不可用'),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(ctx, false),
                                            child: const Text('取消'),
                                          ),
                                          TextButton(
                                            onPressed: () => Navigator.pop(ctx, true),
                                            child: const Text('确认退出'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirm == true) {
                                      await AuthService.logout();
                                      if (mounted) setSheetState(() {});
                                    }
                                  } else {
                                    if (!sheetContext.mounted) return;
                                    Navigator.pop(sheetContext);
                                    if (!mounted) return;
                                    final success = await LoginPage.show(context);
                                    if (success && mounted) setState(() {});
                                  }
                                },
                                style: TextButton.styleFrom(
                                  backgroundColor: AuthService.isLoggedIn
                                      ? textColor.withOpacityCompat(0.1)
                                      : AppColors.techBlue,
                                  foregroundColor: AuthService.isLoggedIn
                                      ? textColor.withOpacityCompat(0.6)
                                      : Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                child: Text(
                                  AuthService.isLoggedIn ? '退出' : '登录',
                                  style: const TextStyle(
                                      fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // ── Section: Daily Check-in ──
                      if (checkinEnabled)
                        _sectionCard(
                          sectionBg: sectionBg,
                          textColor: textColor,
                          child: Row(
                            children: [
                              Icon(
                                _checkedInToday
                                    ? Icons.check_circle_rounded
                                    : Icons.calendar_today_rounded,
                                color: _checkedInToday
                                    ? Colors.green
                                    : AppColors.techBlue,
                                size: 28,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '每日签到',
                                      style: TextStyle(
                                        color: textColor,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _checkedInToday
                                          ? '今日已签到  连续 $_streak 天'
                                          : '签到领 +$checkinPoints 积分${_streak > 0 ? '  已连续 $_streak 天' : ''}',
                                      style: TextStyle(
                                        color: textColor.withOpacityCompat(0.55),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 32,
                                child: TextButton(
                                  onPressed: _checkedInToday || _checkinBusy
                                      ? null
                                      : () => _doCheckin(aiModel, setSheetState),
                                  style: TextButton.styleFrom(
                                    backgroundColor: _checkedInToday
                                        ? textColor.withOpacityCompat(0.1)
                                        : AppColors.techBlue,
                                    foregroundColor: _checkedInToday
                                        ? textColor.withOpacityCompat(0.35)
                                        : Colors.white,
                                    disabledBackgroundColor:
                                        textColor.withOpacityCompat(0.1),
                                    disabledForegroundColor:
                                        textColor.withOpacityCompat(0.35),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: Text(
                                    _checkinBusy
                                        ? '签到中…'
                                        : (_checkedInToday ? '已签到' : '立即签到'),
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // TODO: 广告区域（RemoteConfigService.adEnabled 为 true 时显示）
                      // TODO: 购买区域（RemoteConfigService.purchaseEnabled 为 true 时显示）
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _sectionCard({
    required Color sectionBg,
    required Color textColor,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sectionBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: textColor.withOpacityCompat(0.06),
          width: AppTokens.stroke,
        ),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final aiModel = context.watch<AiModelProvider>();
    final hint = (widget.hintText ?? '').trim();
    return Container(
      decoration: BoxDecoration(
        color: widget.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.textColor.withOpacityCompat(0.08),
          width: AppTokens.stroke,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '剩余积分：${aiModel.pointsBalance}',
                  style: TextStyle(
                    color: widget.textColor.withOpacityCompat(0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (!_checkedInToday && CheckinService.isEnabled)
                TextButton(
                  onPressed: () => _showWalletSheet(aiModel),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: Colors.orange,
                  ),
                  child: const Text('签到领积分',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              if (_checkedInToday || !CheckinService.isEnabled)
                TextButton(
                  onPressed: () => _showWalletSheet(aiModel),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: AppColors.techBlue,
                  ),
                  child: const Text('积分钱包',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          if (hint.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              hint,
              style: TextStyle(
                color: widget.isDark
                    ? const Color(0xFFE6A23C)
                    : const Color(0xFFF57C00),
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
