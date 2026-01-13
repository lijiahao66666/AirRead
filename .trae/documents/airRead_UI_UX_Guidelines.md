# airRead UI/UX Design Guidelines

## 1. Design Philosophy: "Air & AI"
The core design philosophy is "Ethereal Intelligence" (轻盈的智慧). The interface should feel weightless like air, while the AI interactions should feel magical and seamless.

### Keywords
- **Weightless (轻盈)**: Minimalist layout, ample whitespace, glassmorphism, subtle shadows.
- **Intelligent (智能)**: Context-aware controls, fluid AI animations, predictive interactions.
- **Dynamic (灵动)**: Physics-based transitions, micro-interactions, breathing effects.
- **Immersive (沉浸)**: Distraction-free reading, adaptive environments.

## 2. Visual Identity System

### 2.1 Color Palette (Air & Tech)
*Colors are designed to be soft, translucent, and futuristic.*

| Color Name | Hex Value | Usage | Description |
|------------|-----------|-------|-------------|
| **Air Blue** | `#E1F5FE` | Primary Background (Day) | Light, airy, sky-like base. |
| **Mist White** | `#F5F9FA` | Surface / Cards | Slightly off-white for depth. |
| **Tech Blue** | `#29B6F6` | Primary Accent / AI | Active states, AI highlights. |
| **Deep Space** | `#263238` | Text (Day) / Background (Night) | High contrast text, deep mode bg. |
| **Neon Cyan** | `#00E5FF` | AI Glow / Effects | Used for AI processing animations. |
| **Soft Grey** | `#B0BEC5` | Secondary Text | De-emphasized information. |

**Gradients:**
- **AI Flow**: `Linear Gradient (#29B6F6 -> #00E5FF)` for AI buttons and processing bars.
- **Glass Surface**: `White with 60% Opacity + Background Blur (10px)` for overlays.

### 2.2 Typography
*Clean, modern, and highly legible.*

- **Font Family**:
  - English: *Inter* or *SF Pro Text* (System default preferred for familiarity).
  - Chinese: *Noto Sans SC* or *PingFang SC*.
- **Scale**:
  - **Heading 1**: 24sp, Light weight (Airy feel).
  - **Heading 2**: 20sp, Medium weight.
  - **Body Text**: 16sp-18sp (User adjustable), Regular/Book weight.
  - **Caption**: 12sp, Light weight.

### 2.3 Iconography
- **Style**: Thin strokes (1.5px), rounded corners, open shapes.
- **State**:
  - *Inactive*: Grey stroke, transparent fill.
  - *Active*: Tech Blue stroke, slight glow effect.

## 3. Motion & Interaction Design (The "Soul" of AirRead)

### 3.1 Physics & Transitions
*All movements should follow natural physics - no abrupt cuts.*

- **Page Transitions**:
  - *Book Mode*: Realistic curling page turn (Physics-based).
  - *Scroll Mode*: Inertial scrolling with rubber-band effect at edges.
- **Navigation**:
  - *Hero Animations*: Book covers float from shelf to reading view.
  - *Drawer*: Slide in with a slight bounce (spring simulation).

### 3.2 Micro-interactions
- **Buttons**: Scale down (95%) on press, release with a spring effect.
- **Toggles**: Smooth morphing shapes instead of rigid switches.
- **Loading**:
  - *Standard*: A thin, breathing circular line (Air Blue to Tech Blue).
  - *AI Processing*: A "shimmering wave" effect over the text being analyzed.

### 3.3 Gestures (No Superfluous Actions)
*Maximize screen estate by using gestures over buttons.*

- **Single Tap (Center)**: Toggle UI (Immersive Mode).
- **Edge Slide (Left/Right)**: Back / Forward (or Page Turn).
- **Two-finger Pinch**: Adjust font size directly (Real-time preview).
- **Long Press (Text)**: Trigger AI Context Menu (Translation, Summary, Highlight).
- **Double Tap (Paragraph)**: AI Focus (Dim other paragraphs, highlight current).

## 4. AI Visualization

### 4.1 The "AI Breath"
When AI is active (thinking/processing), the UI should exhibit a subtle "breathing" animation.
- **Visual**: A soft, pulsing glow around the AI assistant icon or the selected text.
- **Feedback**: Color changes from Blue (Idle) to Cyan/Purple Gradient (Thinking) to Green (Success).

### 4.2 Dynamic Highlighting
Instead of static yellow blocks, use:
- **Liquid Underline**: An animated underline that draws itself like ink.
- **Focus Mode**: When AI extracts key points, the text glows softly while background text dims slightly (Focus depth effect).

### 4.3 Chat/Result Cards
AI results (summaries, translations) appear in **Glassmorphism Cards**:
- Floating above the text.
- Background blur to maintain context but ensure readability.
- Dismissable with a simple swipe down.

## 5. UI Architecture Specifics

### 5.1 Home (The Bookshelf)
- **Layout**: Minimalist grid. Covers have soft, diffuse shadows (elevation) to look like they are floating.
- **Header**: Collapses into a transparent blur on scroll.

### 5.2 Reading View (The Canvas)
- **Zero UI**: By default, only text is visible.
- **Floating Controls**: A small, semi-transparent pill-shaped capsule at the bottom center (dynamic island style) for quick AI access.

### 5.3 AI Hub
- **Trigger**: Swipe up from the bottom capsule.
- **Presentation**: A modal sheet with frosted glass effect. Icons for "Translate", "Summarize", "Visualize" float in.

---
*Implementation Note for Flutter:*
- Use `BackdropFilter` for glassmorphism.
- Use `Hero` widgets for shared element transitions.
- Use `Rive` or `Lottie` for complex AI animations.
- Use `CustomPainter` for liquid highlights.
