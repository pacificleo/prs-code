ids_to_remove = [
    "32513D1E25BB4F418CABB2A8",
    "8B2985744DB94333AE1B5878",
    "899A0B6B6B42424B92CD20C2",
    "D6D054282F2E3EBF00D70ED5",
    "D6D054272F2E3EBF00D70ED5",
    "D6D054262F2E3EB300D70ED5"
]

import sys

with open('cherrylily.xcodeproj/project.pbxproj', 'r') as f:
    lines = f.readlines()

new_lines = []
skip_depth = 0

for line in lines:
    if skip_depth > 0:
        if '{' in line:
            skip_depth += line.count('{')
        if '}' in line:
            skip_depth -= line.count('}')
        continue
    
    should_skip = False
    for target_id in ids_to_remove:
        if target_id in line:
            if '=' in line and '{' in line and target_id in line.split('=')[0]:
                should_skip = True
                skip_depth += line.count('{') - line.count('}')
                break
            else:
                should_skip = True
                break
    
    if not should_skip:
        new_lines.append(line)

with open('cherrylily.xcodeproj/project.pbxproj', 'w') as f:
    f.writelines(new_lines)
