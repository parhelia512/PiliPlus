class VideoTagItem {
  int? tagId;
  String? tagName;
  String? musicId;
  String? jumpUrl;

  VideoTagItem({
    this.tagId,
    this.tagName,
    this.musicId,
    this.jumpUrl,
  });

  factory VideoTagItem.fromJson(Map<String, dynamic> json) => VideoTagItem(
    tagId: json["tag_id"],
    tagName: json["tag_name"],
    musicId: json["music_id"],
    jumpUrl: json["jump_url"],
  );
}
