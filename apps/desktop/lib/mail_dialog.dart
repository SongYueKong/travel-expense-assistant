import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'services.dart';
import 'app_preferences.dart';
import 'trip_dates.dart';
import 'mail_providers.dart';

class MailImportDialog extends StatefulWidget {
  final ProcessingClient engine;
  final Map<String, dynamic>? previous;
  final MailboxPreferences? preferences;
  final TripPeriod? tripPeriod;
  const MailImportDialog(
      {super.key,
      required this.engine,
      this.previous,
      this.preferences,
      this.tripPeriod});
  @override
  State<MailImportDialog> createState() => _MailImportDialogState();
}

class _MailImportDialogState extends State<MailImportDialog> {
  final account = TextEditingController(), code = TextEditingController();
  String provider = 'qq';
  late DateTimeRange range;
  List<Map<String, dynamic>> folders = [
    {'mailbox': 'INBOX', 'name': '收件箱'}
  ];
  Set<String> selected = {'INBOX'};
  bool busy = false, cancelling = false, connected = false;
  bool credentialBusy = false,
      hasStoredCredential = false,
      credentialFailed = false;
  int credentialRevision = 0, codeRevision = 0;
  String? credentialStatus;
  String? preferenceStatus;
  bool defaultLoading = false, defaultSaving = false, preferenceFailed = false;
  String? error, jobId, paymentDirectory;
  Map<String, dynamic>? report;
  @override
  void initState() {
    super.initState();
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    range = DateTimeRange(
        start: DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 30)),
        end: DateTime(now.year, now.month, now.day));
    if (widget.tripPeriod != null) {
      range = DateTimeRange(
          start: widget.tripPeriod!.mailStart, end: widget.tripPeriod!.mailEnd);
    }
    if (widget.previous != null) {
      account.text = widget.previous!['account'] ?? '';
      provider = providerById(widget.previous!['provider'] ?? '') != null
          ? widget.previous!['provider']
          : providerForAccount(account.text) ?? 'qq';
    }
    if (widget.preferences == null) {
      unawaited(loadSavedCredential());
    } else {
      defaultLoading = true;
      unawaited(loadDefaultMailbox());
    }
  }

  Future<void> loadDefaultMailbox() async {
    final revision = credentialRevision,
        inputRevision = codeRevision,
        initialAccount = account.text,
        initialProvider = provider;
    bool untouched() =>
        mounted &&
        revision == credentialRevision &&
        inputRevision == codeRevision &&
        account.text == initialAccount &&
        provider == initialProvider;
    var loadCredential = false;
    try {
      final saved = await widget.preferences!.loadDefaultMailbox();
      if (!untouched()) return;
      loadCredential = true;
      if (saved != null) {
        setState(() {
          account.text = saved.account;
          provider = saved.provider;
          preferenceStatus = '已带入本机默认邮箱，新建差旅也会使用此账号';
        });
      }
    } catch (e) {
      if (untouched()) {
        loadCredential = true;
        setState(() {
          preferenceStatus = '默认邮箱读取失败：$e；仍可手工填写';
          preferenceFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => defaultLoading = false);
    }
    if (loadCredential && mounted) await loadSavedCredential();
  }

  Future<bool> rememberMailbox(Map<String, dynamic> login) async {
    if (widget.preferences == null) return true;
    try {
      final mailbox = MailboxIdentity.fromJson(login);
      setState(() => defaultSaving = true);
      await widget.preferences!.saveDefaultMailbox(mailbox);
      if (mounted &&
          identity()['provider'] == mailbox.provider &&
          identity()['account'] == mailbox.account) {
        setState(() {
          preferenceStatus = '邮箱账号已保存为本机默认，新建差旅自动带入';
          preferenceFailed = false;
        });
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          preferenceStatus = '默认邮箱未能保存：$e；可点击地址右侧的保存按钮重试';
          preferenceFailed = true;
        });
      }
      return false;
    } finally {
      if (mounted) setState(() => defaultSaving = false);
    }
  }

  Future<void> saveMailbox() async {
    if (!validIdentity) {
      setState(() => error = '邮箱地址与所选服务商不符，请填写完整邮箱地址');
      return;
    }
    setState(() => error = null);
    await rememberMailbox(identity());
  }

  Map<String, dynamic> identity() =>
      {'provider': provider, 'account': account.text.trim().toLowerCase()};
  bool get validIdentity {
    return validMailbox(provider, account.text);
  }

  void identityChanged([String? value]) {
    credentialRevision++;
    codeRevision++;
    setState(() {
      if (value != null) provider = value;
      code.clear();
      credentialBusy = false;
      hasStoredCredential = false;
      credentialStatus = null;
      error = null;
      credentialFailed = false;
      connected = false;
      report = null;
      preferenceStatus =
          widget.preferences == null ? null : '连接成功后自动记住邮箱，也可点击地址右侧保存';
      preferenceFailed = false;
      folders = [
        {'mailbox': 'INBOX', 'name': '收件箱'}
      ];
      selected = {'INBOX'};
    });
    unawaited(loadSavedCredential());
  }

  Future<void> loadSavedCredential() async {
    if (!validIdentity) return;
    final revision = ++credentialRevision, inputRevision = codeRevision;
    final request = identity();
    setState(() {
      credentialBusy = true;
      credentialStatus = '正在读取本机授权码…';
      credentialFailed = false;
    });
    try {
      final result = await widget.engine.call('mail.credential.get', request);
      if (!mounted || revision != credentialRevision) return;
      setState(() {
        hasStoredCredential = result['found'] == true;
        if (hasStoredCredential &&
            inputRevision == codeRevision &&
            code.text.isEmpty) {
          code.text = result['authorization_code'];
          credentialStatus = '已从本机读取已保存的授权码';
        } else {
          credentialStatus =
              hasStoredCredential ? '本机已有授权码，保留当前输入' : '本机尚未保存该邮箱的授权码';
        }
      });
    } catch (e) {
      if (mounted && revision == credentialRevision) {
        setState(() {
          credentialStatus = '本机授权码读取失败：$e';
          credentialFailed = true;
        });
      }
    } finally {
      if (mounted && revision == credentialRevision) {
        setState(() => credentialBusy = false);
      }
    }
  }

  Future<bool> persistCredential(Map<String, dynamic> login) async {
    final revision = ++credentialRevision, inputRevision = codeRevision;
    setState(() {
      credentialBusy = true;
      credentialFailed = false;
    });
    try {
      await widget.engine.call('mail.credential.save', login);
      if (!mounted || revision != credentialRevision) return false;
      setState(() {
        hasStoredCredential = true;
        credentialStatus = inputRevision == codeRevision
            ? '授权码已在本机加密保存'
            : '已保存先前输入的授权码，当前修改尚未保存';
      });
      await rememberMailbox(login);
      return true;
    } catch (e) {
      if (mounted && revision == credentialRevision) {
        setState(() {
          credentialStatus = '授权码未能保存：$e；可重试保存，或继续导入已获取的 PDF';
          credentialFailed = true;
        });
      }
      if (mounted && revision == credentialRevision) {
        await rememberMailbox(login);
      }
      return false;
    } finally {
      if (mounted && revision == credentialRevision) {
        setState(() => credentialBusy = false);
      }
    }
  }

  Future<void> saveCredential() async {
    if (account.text.trim().isEmpty || code.text.trim().isEmpty) {
      setState(() => error = '请填写完整邮箱地址和客户端授权码');
      return;
    }
    setState(() => error = null);
    await persistCredential(credentials());
  }

  Future<void> forgetCredential() async {
    final revision = ++credentialRevision, request = identity();
    setState(() {
      credentialBusy = true;
      credentialFailed = false;
    });
    try {
      await widget.engine.call('mail.credential.delete', request);
      if (!mounted || revision != credentialRevision) return;
      setState(() {
        code.clear();
        codeRevision++;
        hasStoredCredential = false;
        credentialStatus = '已删除本机保存的授权码';
        connected = false;
        report = null;
      });
    } catch (e) {
      if (mounted && revision == credentialRevision) {
        setState(() {
          credentialStatus = '授权码删除失败：$e';
          credentialFailed = true;
        });
      }
    } finally {
      if (mounted && revision == credentialRevision) {
        setState(() => credentialBusy = false);
      }
    }
  }

  String day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  Map<String, dynamic> credentials() => {
        'provider': provider,
        'account': account.text.trim(),
        'authorization_code': code.text.trim()
      };
  bool validate() {
    if (account.text.trim().isEmpty || code.text.trim().isEmpty) {
      setState(() => error = '请填写完整邮箱地址和客户端授权码');
      return false;
    }
    if (selected.isEmpty) {
      setState(() => error = '请至少选择一个邮件文件夹');
      return false;
    }
    return true;
  }

  Future<void> test() async {
    if (!validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    final login = credentials();
    try {
      final result = await widget.engine.call('mail.test', login);
      if (!mounted) return;
      setState(() {
        connected = true;
        folders = (result['folders'] as List).cast<Map<String, dynamic>>();
        final inbox = folders
            .where((f) => (f['mailbox'] as String).toUpperCase() == 'INBOX')
            .firstOrNull;
        selected = {inbox?['mailbox'] ?? folders.first['mailbox']};
      });
      await persistCredential(login);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> start() async {
    if (!validate()) return;
    setState(() {
      busy = true;
      cancelling = false;
      error = null;
      report = null;
      jobId = null;
    });
    final login = credentials();
    try {
      final started = await widget.engine.call('mail.start', {
        ...login,
        'start_date': day(range.start),
        'end_date': day(range.end),
        'folders': selected.toList()
      });
      jobId = started['jobId'];
      while (mounted) {
        final current = Map<String, dynamic>.from(
            await widget.engine.call('mail.status', {'job_id': jobId}));
        if (!mounted) return;
        setState(() => report = current);
        if (current['state'] != 'running') {
          var persisted = true;
          if ((current['state'] == 'done' && current['complete'] == true) ||
              (current['files'] as List).isNotEmpty) {
            persisted = await persistCredential(login);
            if (!mounted) return;
          }
          setState(() => busy = false);
          if (current['state'] == 'error') {
            setState(() => error = current['error'] ?? '邮箱获取失败');
          }
          if (persisted &&
              current['complete'] == true &&
              (current['files'] as List).isNotEmpty) {
            finish();
          }
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  Future<void> cancel() async {
    if (jobId == null) return;
    setState(() => cancelling = true);
    try {
      await widget.engine.call('mail.cancel', {'job_id': jobId});
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  void finish() {
    if (busy ||
        credentialBusy ||
        report == null ||
        (report!['files'] as List).isEmpty) {
      return;
    }
    Navigator.pop(context, {
      'report': {...report!, 'provider': provider},
      'paymentDirectory': paymentDirectory
    });
  }

  @override
  void dispose() {
    credentialRevision++;
    account.dispose();
    code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final files = report?['files'] as List? ?? [];
    final pending = report?['pending'] as List? ?? [];
    final failures = report?['failures'] as List? ?? [];
    return PopScope(
        canPop: !busy,
        child: AlertDialog(
            scrollable: true,
            title: const Text('从邮箱获取发票'),
            content: SizedBox(
                width: 700,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          '在邮箱网页版开启 IMAP 服务，按服务商要求填写客户端授权码或客户端专用密码。软件只读取邮件；凭据保存在本机 Windows 凭据管理器，同一邮箱下次自动读取。'),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                          key: ValueKey('mail-provider-$provider'),
                          initialValue: provider,
                          decoration: const InputDecoration(labelText: '邮箱服务商'),
                          items: [
                            for (final p in mailProviders)
                              DropdownMenuItem(
                                  value: p.id, child: Text(p.label))
                          ],
                          onChanged: busy ? null : (v) => identityChanged(v)),
                      TextField(
                          controller: account,
                          enabled: !busy,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                              labelText: '完整邮箱地址',
                              hintText:
                                  '例如 name@${providerById(provider)!.domains.first}',
                              suffixIcon: widget.preferences == null
                                  ? null
                                  : IconButton(
                                      tooltip: '保存为本机默认邮箱',
                                      onPressed: busy ||
                                              defaultLoading ||
                                              defaultSaving
                                          ? null
                                          : saveMailbox,
                                      icon: const Icon(
                                          Icons.bookmark_add_outlined))),
                          onChanged: (_) => identityChanged()),
                      TextField(
                          controller: code,
                          enabled: !busy,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          onChanged: (_) {
                            codeRevision++;
                            setState(() {
                              connected = false;
                              error = null;
                              report = null;
                              credentialStatus = '连接成功后将自动保存授权码，也可点击“保存授权码”';
                              credentialFailed = false;
                            });
                          },
                          decoration: const InputDecoration(
                              labelText: '客户端授权码',
                              helperText: '填写授权码，非网页登录密码')),
                      Wrap(spacing: 12, children: [
                        OutlinedButton.icon(
                            onPressed: busy ||
                                    credentialBusy ||
                                    defaultLoading ||
                                    defaultSaving
                                ? null
                                : saveCredential,
                            icon: const Icon(Icons.lock_outline),
                            label: const Text('保存授权码')),
                        TextButton(
                            onPressed: busy ||
                                    credentialBusy ||
                                    defaultLoading ||
                                    defaultSaving ||
                                    !hasStoredCredential
                                ? null
                                : forgetCredential,
                            child: const Text('忘记授权码')),
                      ]),
                      const Text('成功连接后自动保存，仅供本机当前 Windows 用户使用，不写入报账任务或导出文件。',
                          style: TextStyle(color: Colors.blueGrey)),
                      if (credentialStatus != null)
                        Text(credentialStatus!,
                            style: TextStyle(
                                color: credentialFailed
                                    ? Colors.deepOrange
                                    : Colors.teal)),
                      if (defaultLoading) const Text('正在读取本机默认邮箱…'),
                      if (preferenceStatus != null)
                        Text(preferenceStatus!,
                            style: TextStyle(
                                color: preferenceFailed
                                    ? Colors.deepOrange
                                    : Colors.teal)),
                      const SizedBox(height: 8),
                      Row(children: [
                        OutlinedButton(
                            onPressed: busy ||
                                    credentialBusy ||
                                    defaultLoading ||
                                    defaultSaving
                                ? null
                                : test,
                            child: const Text('测试连接并读取文件夹')),
                        const SizedBox(width: 12),
                        if (connected)
                          const Text('连接成功',
                              style: TextStyle(color: Colors.teal))
                      ]),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                          icon: const Icon(Icons.date_range),
                          onPressed: busy
                              ? null
                              : () async {
                                  final picked = await showDateRangePicker(
                                      context: context,
                                      initialDateRange: range,
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime(2101, 1, 1));
                                  if (picked != null && mounted) {
                                    setState(() {
                                      range = picked;
                                      report = null;
                                    });
                                  }
                                },
                          label: Text(
                              '接收日期：${day(range.start)} 至 ${day(range.end)}（北京时间）')),
                      const Text('结束日期包含整天；范围内 PDF 附件全部检查，不依赖主题关键词。',
                          style: TextStyle(color: Colors.blueGrey)),
                      ExpansionTile(
                          title: Text('邮件文件夹（已选 ${selected.length} 个）'),
                          initiallyExpanded: connected,
                          children: [
                            Wrap(spacing: 8, children: [
                              for (final folder in folders)
                                FilterChip(
                                    label: Text(folder['name']),
                                    selected:
                                        selected.contains(folder['mailbox']),
                                    onSelected: busy
                                        ? null
                                        : (value) => setState(() {
                                              report = null;
                                              if (value) {
                                                selected.add(folder['mailbox']);
                                              } else {
                                                selected
                                                    .remove(folder['mailbox']);
                                              }
                                            }))
                            ])
                          ]),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                          icon: const Icon(Icons.folder_open),
                          onPressed: busy
                              ? null
                              : () async {
                                  final path = await getDirectoryPath(
                                      confirmButtonText: '选择支付截图文件夹');
                                  if (path != null && mounted) {
                                    setState(() => paymentDirectory = path);
                                  }
                                },
                          label: const Text('同时选择支付截图文件夹（可选）')),
                      if (paymentDirectory != null)
                        Text(paymentDirectory!,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                      const Text('也可以先导入发票，稍后在任务中补充支付截图。已确认和人工录入的项目会保留。',
                          style: TextStyle(color: Colors.blueGrey)),
                      if (busy) ...[
                        const SizedBox(height: 16),
                        const LinearProgressIndicator(),
                        Text(cancelling
                            ? '正在取消，已下载附件会保留'
                            : '${report?['folder'] ?? ''} 已扫描 ${report?['scannedMessages'] ?? 0} 封，范围内 ${report?['inRangeMessages'] ?? 0} 封')
                      ],
                      if (report != null) ...[
                        const SizedBox(height: 12),
                        Text(
                            '新增 ${report?['downloaded'] ?? 0} 份 · 重复 ${report?['duplicates'] ?? 0} 份 · 待处理 ${pending.length} 项 · 失败 ${failures.length} 项'),
                        if (report?['state'] == 'cancelled')
                          const Text('获取已取消，可导入已完成的附件，或再次获取以继续。'),
                        if (pending.isNotEmpty || failures.isNotEmpty)
                          ExpansionTile(
                              title: const Text('查看需要处理的邮件'),
                              children: [
                                for (final item in [...pending, ...failures])
                                  ListTile(
                                      dense: true,
                                      title: Text(item['reason'] ?? '待处理'),
                                      subtitle: Text(
                                          '${item['subject'] ?? item['folder'] ?? ''} ${item['filename'] ?? ''}'))
                              ]),
                        if (files.isNotEmpty)
                          ExpansionTile(
                              title: Text('已获取 ${files.length} 份不同 PDF'),
                              children: [
                                for (final file in files)
                                  ListTile(
                                      dense: true,
                                      title: Text(file['filename']),
                                      subtitle: Text(file['subject'] ?? ''))
                              ]),
                        if (!busy &&
                            files.isEmpty &&
                            report?['state'] == 'done')
                          const Text('所选范围内没有可导入的 PDF。请检查日期、文件夹，或查看待处理邮件。')
                      ],
                      if (error != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: SelectableText(error!,
                                style: const TextStyle(color: Colors.red))),
                    ])),
            actions: [
              if (!busy && report != null)
                TextButton(
                    onPressed: credentialBusy || defaultLoading || defaultSaving
                        ? null
                        : start,
                    child: const Text('重新获取（使用缓存）')),
              if (busy && jobId != null)
                TextButton(
                    onPressed: cancelling ? null : cancel,
                    child: const Text('取消获取')),
              TextButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  child: const Text('关闭')),
              FilledButton(
                  onPressed:
                      busy || credentialBusy || defaultLoading || defaultSaving
                          ? null
                          : (files.isNotEmpty ? finish : start),
                  child: Text(files.isNotEmpty
                      ? '导入已获取的 ${files.length} 份 PDF'
                      : '获取并导入')),
            ]));
  }
}
