import 'package:nocterm/nocterm.dart';

/// Left pane: a scrollable list with a highlighted selection.
/// Navigation itself lives in the parent (vim + arrow keys) so that the
/// selection can be observed from tests; this component only renders.
class TaskList extends StatelessComponent {
  const TaskList({
    super.key,
    required this.tasks,
    required this.selected,
    required this.focused,
    required this.controller,
  });

  final List<String> tasks;
  final int selected;
  final bool focused;
  final ScrollController controller;

  @override
  Component build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: BoxBorder.all(
          color: focused ? Colors.cyan : Colors.gray,
        ),
      ),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        child: ListView.builder(
          controller: controller,
          itemExtent: 1,
          itemCount: tasks.length,
          itemBuilder: (context, index) {
            final isSelected = index == selected;
            return Container(
              decoration: BoxDecoration(
                color: isSelected && focused ? Colors.blue : null,
              ),
              child: Text(
                '${isSelected ? '▶' : ' '} ${tasks[index]}',
                style: TextStyle(
                  color: isSelected ? Colors.brightWhite : Colors.white,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                maxLines: 1,
              ),
            );
          },
        ),
      ),
    );
  }
}
