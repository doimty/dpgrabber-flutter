/// Order filter chain (PORTING_CONTRACT §6.3–§6.5).
///
/// Ported from `pc/engine.py` (`OrderFilter`, `order_matches_items`,
/// `order_item_names`, `order_item_id`, `item_keywords`,
/// `match_always_type`). The filter is rebuilt every poll round
/// (§6.2), so blacklist/keyword changes take effect while listening.
library;

import 'config.dart';
import 'models.dart';

/// Candidate order fields that may hold the grab-type id (§6.5).
/// The real field name is unconfirmed (Q-06); the candidate list +
/// name matching + "unrecognised passes" behaviour is kept as in PC.
const List<String> itemFieldNames = [
  'itemId',
  'itemSwitchId',
  'itemCategoryId',
  'typeId',
  'itemType',
  'serviceItemId',
  'categoryId',
];

/// Candidate order fields that may hold grab-type names (§6.5).
const List<String> itemNameFields = [
  'itemNames',
  'item_names',
  'itemName',
  'item_name',
  'items',
  'serviceNames',
  'serviceName',
  'itemCategoryName',
  'item',
  'itemCategory',
];

/// Built-in synonyms for grab-type ids (§6.5). Only words that
/// literally appear in order names go here; guessed words do not.
const Map<int, List<String>> itemNameSynonyms = {
  465: ['连麦'],
  2666: ['视频'],
  2667: ['游戏'],
};

/// Collect the type names appearing in an order (list or single string;
/// dict values read from `names` / `name` / `itemName`).
List<String> orderItemNames(Map<String, dynamic> order) {
  final names = <String>[];
  for (final key in itemNameFields) {
    final value = order[key];
    if (value == null) continue;
    if (value is List) {
      for (final v in value) {
        if (v != null && v.toString().trim().isNotEmpty) {
          names.add(v.toString().trim());
        }
      }
    } else if (value is Map) {
      for (final innerKey in <String>['names', 'name', 'itemName']) {
        final inner = value[innerKey];
        if (inner is List) {
          for (final v in inner) {
            if (v != null && v.toString().trim().isNotEmpty) {
              names.add(v.toString().trim());
            }
          }
        } else if (inner != null && inner.toString().trim().isNotEmpty) {
          names.add(inner.toString().trim());
        }
      }
    } else if (value.toString().trim().isNotEmpty) {
      names.add(value.toString().trim());
    }
  }
  return names;
}

/// The order's grab-type id, or null when no such field exists.
int? orderItemId(Map<String, dynamic> order) {
  for (final key in itemFieldNames) {
    if (!order.containsKey(key)) continue;
    final value = order[key];
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
  }
  return null;
}

/// Matching words for one grab-type id: the configured `item_name_map`
/// wins, otherwise the built-in synonyms.
List<String> itemKeywords(
    int itemId, Map<String, List<String>>? nameMap) {
  final configured = nameMap?[itemId.toString()];
  if (configured != null && configured.isNotEmpty) {
    return List.of(configured);
  }
  return List.of(itemNameSynonyms[itemId] ?? const <String>[]);
}

/// The first always-allowed base-type word contained in [nameText],
/// or '' when none matches.
String matchAlwaysType(String nameText, List<String>? alwaysTypes) {
  final words = alwaysTypes ?? const ['文字语音条', '文语体验单'];
  for (final word in words) {
    final w = word.trim();
    if (w.isNotEmpty && nameText.contains(w)) return w;
  }
  return '';
}

/// True/False when the type can be decided; null means "unrecognised,
/// let it through, never drop an order" (§6.5).
///
/// Note: the order's `item.ids` are SKU ids (e.g. 59245…) with no
/// relation to grab-type ids 465/2666/2667, so only a hit on a
/// *disabled* type's keyword blocks; anything unrecognised passes.
bool? orderMatchesItems(
  Map<String, dynamic> order,
  Set<int> enabledItems, {
  Map<String, List<String>>? nameMap,
  List<String>? alwaysTypes,
}) {
  if (enabledItems.isEmpty) return true;
  final itemId = orderItemId(order);
  if (itemId != null) return enabledItems.contains(itemId);
  final names = orderItemNames(order).join(' ');
  if (names.isEmpty) return null;
  if (matchAlwaysType(names, alwaysTypes).isNotEmpty) return true;
  final candidates = <int>{...enabledItems};
  if (nameMap != null) {
    for (final key in nameMap.keys) {
      final parsed = int.tryParse(key);
      if (parsed != null) candidates.add(parsed);
    }
  }
  candidates.addAll(itemNameSynonyms.keys);
  var hitEnabled = false;
  var hitDisabled = false;
  for (final switchId in candidates) {
    final words = itemKeywords(switchId, nameMap);
    if (words.isNotEmpty &&
        words.any((word) => word.isNotEmpty && names.contains(word))) {
      if (enabledItems.contains(switchId)) {
        hitEnabled = true;
      } else {
        hitDisabled = true;
      }
    }
  }
  if (hitEnabled) return true;
  if (hitDisabled) return false;
  return null;
}

/// The §6.3 filter chain. [check] returns `(passed, reason)`; the
/// first failing step decides.
class OrderFilter {
  final double minAmount;
  final double maxAmount; // 0 = no limit
  final int memoMode; // 0..3 (§6.4)
  final List<String> memoKeywords; // legacy field (exclude words)
  final List<String> memoExcludeKeywords;
  final List<String> memoIncludeKeywords;
  final Set<String> blacklist;
  final Set<int> enabledItems;
  final Map<String, List<String>> itemNameMap;
  final List<String> itemAlwaysTypes;
  final bool switchListKnown;

  OrderFilter({
    required this.minAmount,
    required this.maxAmount,
    required int memoMode,
    List<String> memoKeywords = const [],
    List<String> memoExcludeKeywords = const [],
    List<String> memoIncludeKeywords = const [],
    List<String> blacklist = const [],
    List<int> enabledItems = const [],
    Map<String, List<String>> itemNameMap = const {
      '465': ['连麦'],
      '2666': ['视频'],
      '2667': ['游戏'],
    },
    List<String> itemAlwaysTypes = const ['文字语音条', '文语体验单'],
    this.switchListKnown = false,
  })  : memoMode = (memoMode == 0 &&
                (memoKeywords.any((k) => k.trim().isNotEmpty) ||
                    memoExcludeKeywords.any((k) => k.trim().isNotEmpty)))
            ? 2
            : memoMode,
        memoKeywords = [
          for (final k in memoKeywords)
            if (k.trim().isNotEmpty) k.trim(),
        ],
        memoExcludeKeywords = [
          for (final k in memoExcludeKeywords)
            if (k.trim().isNotEmpty) k.trim(),
        ],
        memoIncludeKeywords = [
          for (final k in memoIncludeKeywords)
            if (k.trim().isNotEmpty) k.trim(),
        ],
        blacklist = {
          for (final b in blacklist)
            if (b.trim().isNotEmpty) b.trim(),
        },
        enabledItems = {
          for (final i in enabledItems) i,
        },
        itemNameMap = Map.unmodifiable(itemNameMap),
        itemAlwaysTypes = List.unmodifiable(itemAlwaysTypes);

  /// Build a filter from the live config (§6.2: rebuilt every round).
  factory OrderFilter.fromConfig(AppConfig cfg) => OrderFilter(
        minAmount: cfg.minAmount,
        maxAmount: cfg.maxAmount,
        memoMode: cfg.memoMode,
        memoKeywords: cfg.memoKeywords,
        memoExcludeKeywords: cfg.memoExcludeKeywords,
        memoIncludeKeywords: cfg.memoIncludeKeywords,
        blacklist: cfg.blacklist,
        enabledItems: cfg.itemSwitchIds,
        itemNameMap: cfg.itemNameMap,
        itemAlwaysTypes: cfg.itemAlwaysTypes,
        switchListKnown: cfg.itemSwitchKnown,
      );

  /// Effective exclude keywords: the union of the legacy field and the
  /// mode-2 list.
  ///
  /// Deviation from PC, noted: PC's `build_filter` passes only the
  /// legacy `memo_keywords` into `OrderFilter`, so a keyword added
  /// directly to `memo_exclude_keywords` would silently never fire.
  /// The contract (§1.5) gives the Dart filter both lists, and the
  /// union is the only reading under which mode 2 works as configured.
  List<String> get effectiveExcludeKeywords =>
      {...memoKeywords, ...memoExcludeKeywords}.toList();

  ({bool passed, String reason}) check(Map<String, dynamic> order) {
    // TODO(OPEN-Q05): PC's filter rejects when the `totalAmount` key is
    // missing and never applies the `servicePrice` fallback, even
    // though PROTOCOL.md §5.2 says to use it when `totalAmount` is
    // 0/missing. Per the contract's tendency, the fallback is applied
    // here: only when BOTH are absent/zero is the order rejected.
    final hasTotal = order.containsKey('totalAmount') &&
        order['totalAmount'] is num &&
        (order['totalAmount'] as num) != 0;
    final hasServicePrice = order.containsKey('servicePrice') &&
        order['servicePrice'] is num &&
        (order['servicePrice'] as num) != 0;
    if (!hasTotal && !hasServicePrice) {
      return (passed: false, reason: '订单缺少金额字段');
    }
    if (orderIdOf(order).isEmpty) {
      return (passed: false, reason: '订单缺少 id 字段');
    }
    final amount = Order(order).amountYuan;
    final wechat = order['userWechatId']?.toString() ?? '';
    if (wechat.isNotEmpty && blacklist.contains(wechat)) {
      return (passed: false, reason: '客户在黑名单中: $wechat');
    }
    if (amount < minAmount) {
      return (
        passed: false,
        reason: '金额 ${amount.toStringAsFixed(2)} 元低于最低金额',
      );
    }
    if (maxAmount > 0 && amount > maxAmount) {
      return (
        passed: false,
        reason: '金额 ${amount.toStringAsFixed(2)} 元高于最高金额',
      );
    }
    // All-closed: the platform list was fetched and is empty, so every
    // non-base type is blocked. Without a fetched list, do not limit
    // (avoid dropping orders at startup).
    if (switchListKnown && enabledItems.isEmpty) {
      final namesAll = orderItemNames(order).join(' ');
      if (namesAll.isNotEmpty &&
          matchAlwaysType(namesAll, itemAlwaysTypes).isEmpty) {
        final candidates = <int>{...itemNameSynonyms.keys};
        for (final key in itemNameMap.keys) {
          final parsed = int.tryParse(key);
          if (parsed != null) candidates.add(parsed);
        }
        for (final switchId in candidates.toList()..sort()) {
          for (final word in itemKeywords(switchId, itemNameMap)) {
            if (word.isNotEmpty && namesAll.contains(word)) {
              return (passed: false, reason: '接单类型已全部关闭（$namesAll）');
            }
          }
        }
      }
    }
    if (enabledItems.isNotEmpty) {
      final matched = orderMatchesItems(
        order,
        enabledItems,
        nameMap: itemNameMap,
        alwaysTypes: itemAlwaysTypes,
      );
      if (matched == false) {
        var names = orderItemNames(order).join('、');
        if (names.isEmpty) {
          final itemId = orderItemId(order);
          names = itemId != null ? '类型 id $itemId' : '未知类型';
        }
        return (passed: false, reason: '该接单类型已关闭（$names）');
      }
    }
    final memo = order['userMemo']?.toString() ?? '';
    if (memoMode == 1 && memo.isNotEmpty) {
      return (passed: false, reason: '订单有备注，不符合要求');
    }
    if (memoMode == 2 && memo.isNotEmpty) {
      final lowered = memo.toLowerCase();
      for (final keyword in effectiveExcludeKeywords) {
        if (keyword.toLowerCase().isNotEmpty &&
            lowered.contains(keyword.toLowerCase())) {
          return (passed: false, reason: '订单备注命中关键词[$keyword]');
        }
      }
    }
    if (memoMode == 3 && memoIncludeKeywords.isNotEmpty) {
      final lowered = memo.toLowerCase();
      final hit = memoIncludeKeywords.any(
          (k) => k.toLowerCase().isNotEmpty && lowered.contains(k.toLowerCase()));
      if (!hit) {
        return (passed: false, reason: '订单备注不含指定关键词');
      }
    }
    return (passed: true, reason: '');
  }
}
