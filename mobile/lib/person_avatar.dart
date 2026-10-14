import 'dart:typed_data';
import 'package:flutter/material.dart';

class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.photo,
    this.radius = 20,
  });
  final String name;
  final Uint8List? photo;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    final initials = parts.isEmpty
        ? '?'
        : parts.take(2).map((s) => s.characters.first).join().toUpperCase();
    return CircleAvatar(
      radius: radius,
      child: ClipOval(
        child: photo == null
            ? Text(initials)
            : Image.memory(
                photo!,
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, error, stack) => Text(initials),
              ),
      ),
    );
  }
}
