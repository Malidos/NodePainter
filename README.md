# NodePainter

![Banner](https://github.com/user-attachments/assets/304b62f6-2923-4fd1-bd73-aa95d63bf076)

### Edit your terrain procedurally using Nodes

## How does it work?

+ Add a `NodePainterContainer` as a child of a Terrain3D node. The container handles all heightmap generation, while taking its child shapes into account in the order of the scene tree. The Node now replaces Terrain3Ds own way to edit the terrain.

+ Add a `NodePainterShape` as a child of the Container and add a desired shape in the inspector.

+ Move the Node to its intended position and edit its shape to your liking.

+ Shapes also support scaling and rotating on the y-axis.

### Shapes

NodePainter supports four shapes: Circles, Rectangles, Polyongs and Paths, which can be combined into hills, lakes, canyons or even mountain ranges.

| ![circle](https://github.com/user-attachments/assets/38be4893-414d-45a5-94c1-25ce62289b71) | ![rectangle](https://github.com/user-attachments/assets/3c4b7151-c98b-4f67-9ff7-ce17cb95bf21) | ![polygon](https://github.com/user-attachments/assets/0a5b58e0-5bd9-4be5-8d3a-9260c00cb108) | ![path](https://github.com/user-attachments/assets/5432823f-2e5f-4d94-9315-939d7848054e) |
|--------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------|
| Circle                                                                                     | Rectangle                                                                                     | Polygon                                                                                     | Path                                                                                     |

While Circles and Rectangles offer an easy use, Polyongs open up more complex shapes. But true creative freedom come with the use of paths which are currently the only shapes that supports blending between multiple heights in a single shape.

## Installation

1. Make sure to install ![Terrain3D](https://github.com/TokisanGames/Terrain3D) as this plugin only helps with a procedual heightmap generation.

2. Download the repository and drop its addons folder in your regular project directory.

3. Activate the plugin in your project settings.

## License

The plugin is distributed under the [MIT License](https://github.com/Malidos/NodePainter/blob/main/LICENSE).
