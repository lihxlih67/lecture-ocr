"""Local OCR worker. Missing OCR models are downloaded on first use."""

import json
import os
import re
import sys
import tempfile
import urllib.error
import traceback
import urllib.request
from pathlib import Path


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def cache_dirs():
    selected = os.environ.get("LECTURE_OCR_MODEL_DIR")
    raw = os.environ.get("PADDLE_PDX_CACHE_HOME")
    if not raw:
        raise RuntimeError("Не задан каталог моделей PaddleX.")
    paddle_models = Path(raw) / "official_models"
    candidates = [Path(selected)] if selected else []
    if paddle_models not in candidates:
        candidates.append(paddle_models)
    return candidates


def cache_dir():
    raw = os.environ.get("PADDLE_PDX_CACHE_HOME")
    if not raw:
        raise RuntimeError("Не задан каталог моделей PaddleX.")
    return Path(raw) / "official_models"


def local_model(name, required):
    for root in cache_dirs():
        folder = root / name
        if all((folder / entry).is_file() for entry in required):
            return folder
    return None


CYRILLIC_MODEL_REVISION = "4f35024ef590b24c12101abfa5184c7fbb5f7299"
CYRILLIC_MODEL_FILES = (
    "inference.yml",
    "inference.onnx",
)


def ensure_cyrillic_model():
    folder = cache_dir() / "PP-OCRv6_medium_rec_cyrillic_onnx"
    existing = local_model("PP-OCRv6_medium_rec_cyrillic_onnx", CYRILLIC_MODEL_FILES)
    if existing and (existing / "inference.onnx").stat().st_size >= 50_000_000:
        return existing

    folder.mkdir(parents=True, exist_ok=True)
    base_url = (
        "https://huggingface.co/metrika-labs/PP-OCRv6_medium_rec_cyrillic_onnx"
        f"/resolve/{CYRILLIC_MODEL_REVISION}"
    )
    for filename in CYRILLIC_MODEL_FILES:
        destination = folder / filename
        if destination.is_file() and destination.stat().st_size > 0:
            if filename != "inference.onnx" or destination.stat().st_size >= 50_000_000:
                continue
        emit({"event": "status", "stage": "models", "message": f"Скачиваю кириллическую модель · {filename}"})
        request = urllib.request.Request(
            f"{base_url}/{filename}",
            headers={"User-Agent": "LectureOCR/1.3"},
        )
        temporary = folder / f".{filename}.download"
        try:
            with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
                expected = int(response.headers.get("Content-Length", "0"))
                downloaded = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
                    downloaded += len(chunk)
                    if expected:
                        emit({"event": "model_download", "file": filename,
                              "downloaded": downloaded, "total": expected})
                output.flush()
                os.fsync(output.fileno())
            if expected and downloaded != expected:
                raise IOError(f"Файл {filename} загружен не полностью.")
            if filename == "inference.onnx" and downloaded < 50_000_000:
                raise IOError("Скачанный файл ONNX слишком мал и, вероятно, повреждён.")
            os.replace(temporary, destination)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
    return folder


def unpack(result):
    data = result.json
    if isinstance(data, str):
        data = json.loads(data)
    return data.get("res", data)


def document_output_image(result):
    """Return the orientation-corrected/unwarped page used for OCR, if exposed."""
    try:
        preprocessor = result.get("doc_preprocessor_res")
        if preprocessor is not None:
            return preprocessor.get("output_img")
    except Exception:
        pass
    return None


def bbox_xyxy(raw):
    if raw is None:
        return None
    try:
        values = [float(v) for v in raw]
        if len(values) == 4:
            x0, y0, x1, y1 = values
        elif len(values) >= 6 and len(values) % 2 == 0:
            xs, ys = values[::2], values[1::2]
            x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
        else:
            return None
        return [x0, y0, x1, y1] if x1 > x0 and y1 > y0 else None
    except (TypeError, ValueError):
        return None


def normalized_bbox(raw, width, height):
    box = bbox_xyxy(raw)
    if not box or width <= 0 or height <= 0:
        return None
    x0, y0, x1, y1 = box
    x0, x1 = max(0.0, min(width, x0)), max(0.0, min(width, x1))
    y0, y1 = max(0.0, min(height, y0)), max(0.0, min(height, y1))
    return [x0 / width, y0 / height, (x1 - x0) / width, (y1 - y0) / height]


def as_dict(value):
    if hasattr(value, "tolist"):
        value = value.tolist()
    if isinstance(value, tuple):
        value = list(value)
    return value


def clean_kind(label):
    text = (label or "text").lower().replace(" ", "_")
    if "title" in text or text in {"heading", "doc_title"}:
        return "heading"
    if "list" in text or text in {"bullet", "list_item"}:
        return "list"
    if text in {"table", "image", "figure", "formula", "chart"}:
        return text
    return "paragraph"


def likely_handwriting(text, score, box, image_height):
    latin = sum(ch.isascii() and ch.isalpha() for ch in text)
    cyrillic = sum("\u0400" <= ch <= "\u052f" for ch in text)
    letters = latin + cyrillic
    mixed_or_latin = letters > 0 and latin / letters >= 0.18
    isolated_top_note = box and (box[1] + box[3] / 2) < image_height * 0.22 and score < 0.97
    return mixed_or_latin or score < 0.72 or isolated_top_note


def get_lines(overall, image_width, image_height, handwritten_recognizer=None):
    texts = list(overall.get("rec_texts", []) or [])
    scores = as_dict(overall.get("rec_scores", [])) or []
    boxes = as_dict(overall.get("rec_boxes", [])) or []
    if not boxes:
        boxes = as_dict(overall.get("dt_polys", [])) or []
    try:
        import cv2
        import numpy as np
    except ImportError:
        cv2 = np = None

    lines = []
    for index, text in enumerate(texts):
        text = str(text).strip()
        if not text:
            continue
        box = bbox_xyxy(boxes[index]) if index < len(boxes) else None
        score = float(scores[index]) if index < len(scores) else 0.0
        if handwritten_recognizer and box and likely_handwriting(text, score, box, image_height):
            try:
                if cv2 is not None and np is not None:
                    image = cv2.imread(os.environ.get("LECTURE_OCR_CURRENT_IMAGE", ""))
                    if image is not None:
                        x0, y0, x1, y1 = [int(round(v)) for v in box]
                        pad_x = max(2, int((x1 - x0) * 0.025))
                        pad_y = max(2, int((y1 - y0) * 0.18))
                        crop = image[max(0, y0-pad_y):min(image.shape[0], y1+pad_y),
                                     max(0, x0-pad_x):min(image.shape[1], x1+pad_x)]
                        if crop.size:
                            candidate = handwritten_recognizer.predict(
                                input=cv2.cvtColor(crop, cv2.COLOR_BGR2RGB)
                            )
                            candidate_data = unpack(candidate[0]) if candidate else {}
                            hand_text = str(candidate_data.get("rec_text", "")).strip()
                            hand_score = float(candidate_data.get("rec_score", 0.0) or 0.0)
                            # For mixed/Latin-looking output prefer a plausible Cyrillic hypothesis;
                            # otherwise require a clear confidence advantage to avoid replacing print.
                            hand_cyr = sum("\u0400" <= ch <= "\u052f" for ch in hand_text)
                            latin = sum(ch.isascii() and ch.isalpha() for ch in text)
                            if hand_text and ((latin > 0 and hand_cyr > 0 and hand_score >= 0.25) or hand_score >= score + 0.04):
                                text, score = hand_text, hand_score
            except Exception:
                # Recognition falls back to the established printed-text result.
                pass
        lines.append({"text": text, "score": score, "box": box})
    return lines


def ordered_text_rows(lines):
    """Group slightly misaligned word boxes into visual lines, then read left to right."""
    candidates = sorted(
        enumerate(lines),
        key=lambda pair: ((pair[1]["box"] or [0, 0, 0, 0])[1], pair[0]),
    )
    rows = []
    for sequence, line in candidates:
        box = line["box"]
        if not box:
            rows.append({"members": [(sequence, line)], "box": None, "center": float(sequence)})
            continue
        y0, y1 = box[1], box[3]
        height = max(1.0, y1 - y0)
        center = (y0 + y1) / 2
        best, best_distance = None, float("inf")
        for row in rows:
            row_box = row["box"]
            if not row_box:
                continue
            overlap = max(0.0, min(y1, row_box[3]) - max(y0, row_box[1]))
            row_height = max(1.0, row_box[3] - row_box[1])
            overlap_ratio = overlap / min(height, row_height)
            distance = abs(center - row["center"])
            same_row = overlap_ratio >= 0.35 or distance <= 0.42 * max(height, row_height)
            if same_row and distance < best_distance:
                best, best_distance = row, distance
        if best is None:
            rows.append({"members": [(sequence, line)], "box": list(box), "center": center})
        else:
            best["members"].append((sequence, line))
            best["box"] = [min(best["box"][0], box[0]), min(best["box"][1], box[1]),
                           max(best["box"][2], box[2]), max(best["box"][3], box[3])]
            best["center"] = sum((item[1]["box"][1] + item[1]["box"][3]) / 2
                                 for item in best["members"]) / len(best["members"])
    rows.sort(key=lambda row: row["center"])
    result = []
    for row in rows:
        members = sorted(row["members"], key=lambda pair: (pair[1]["box"] or [pair[0]])[0])
        text = " ".join(member[1]["text"].strip() for member in members if member[1]["text"].strip())
        if text:
            result.append({"text": text, "box": row["box"]})
    return result


def split_into_paragraphs(lines):
    rows = ordered_text_rows(lines)
    if not rows:
        return ""
    paragraphs, current = [], rows[0]["text"]
    previous = rows[0]["box"]
    for row in rows[1:]:
        box, text = row["box"], row["text"]
        starts_list = bool(re.match(r"^\s*(?:[—–−-]|[•●▪])\s*", text))
        separate_paragraph = False
        if box and previous:
            prev_center = (previous[1] + previous[3]) / 2
            center = (box[1] + box[3]) / 2
            height = max(1.0, previous[3] - previous[1], box[3] - box[1])
            separate_paragraph = center - prev_center > height * 1.9
        if starts_list or separate_paragraph:
            paragraphs.append(current.strip())
            current = text
        elif current.rstrip().endswith("-") and text[:1].islower():
            current = current.rstrip()[:-1] + text.lstrip()
        else:
            current = f"{current.rstrip()} {text.lstrip()}"
        previous = box or previous
    paragraphs.append(current.strip())
    return "\n".join(part for part in paragraphs if part)


def structure_blocks(payload, width, height, handwritten_recognizer=None):
    overall = payload.get("overall_ocr_res", {}) or {}
    lines = get_lines(overall, width, height, handwritten_recognizer)
    raw_blocks = payload.get("parsing_res_list", []) or []
    result, used = [], set()
    for index, block in enumerate(raw_blocks):
        label = str(block.get("block_label", "text"))
        box = bbox_xyxy(block.get("block_bbox"))
        inside = []
        if box:
            x0, y0, x1, y1 = box
            for line_index, line in enumerate(lines):
                line_box = line["box"]
                if line_box and line_index not in used:
                    cx, cy = (line_box[0] + line_box[2]) / 2, (line_box[1] + line_box[3]) / 2
                    if x0 - 4 <= cx <= x1 + 4 and y0 - 4 <= cy <= y1 + 4:
                        inside.append(line)
                        used.add(line_index)
        content = split_into_paragraphs(inside) if inside else str(block.get("block_content", "")).strip()
        if not content:
            continue
        kind = clean_kind(label)
        if kind == "paragraph" and re.search(r"(?m)^\s*(?:[—–−-]|[•●▪])\s*", content):
            kind = "list"
        result.append({
            "id": str(index), "kind": kind, "text": content,
            "bbox": normalized_bbox(box, width, height),
        })
    for i, line in enumerate(lines):
        if i in used:
            continue
        text = line["text"].strip()
        if text:
            result.append({"id": f"fallback-{i}", "kind": "paragraph", "text": text,
                           "bbox": normalized_bbox(line["box"], width, height)})
    if result:
        header_notes = [item for item in result if item["id"].startswith("fallback-")
                        and item.get("bbox") and item["bbox"][1] < 0.12]
        if header_notes:
            header_notes.sort(key=lambda item: item["bbox"][0])
            top = header_notes[0]
            if len(header_notes) > 1:
                y_centers = [item["bbox"][1] + item["bbox"][3] / 2 for item in header_notes]
                if max(y_centers) - min(y_centers) <= 0.04:
                    top["text"] = " ".join(item["text"].strip() for item in header_notes)
                    boxes = [item["bbox"] for item in header_notes]
                    x0, y0 = min(box[0] for box in boxes), min(box[1] for box in boxes)
                    x1 = max(box[0] + box[2] for box in boxes)
                    y1 = max(box[1] + box[3] for box in boxes)
                    top["bbox"] = [x0, y0, x1 - x0, y1 - y0]
                    for other in header_notes[1:]:
                        result.remove(other)
            top["kind"] = "heading"
        result.sort(key=lambda item: ((item["bbox"] or [0, 0, 0, 0])[1],
                                      (item["bbox"] or [0, 0, 0, 0])[0]))
        # Some list rows lose their dash during OCR. Preserve list styling for
        # same-indent runs and for undashed rows between two detected bullets.
        for index, item in enumerate(result):
            box = item.get("bbox")
            if not box or box[0] < 0.17 or item["kind"] != "paragraph":
                continue
            run = [index]
            cursor = index + 1
            while cursor < len(result):
                other = result[cursor]
                other_box = other.get("bbox")
                if (not other_box or other["kind"] != "paragraph" or other_box[0] < 0.17
                        or abs(other_box[0] - box[0]) > 0.045
                        or other_box[1] - (result[cursor - 1].get("bbox") or [0, 0, 0, 0])[1] > 0.055):
                    break
                run.append(cursor)
                cursor += 1
            if len(run) >= 2:
                for member in run:
                    result[member]["kind"] = "list"
        for index, item in enumerate(result):
            if item["kind"] != "list" or not re.search(r"(?m)^\s*(?:[—–−-]|[•●▪])\s*", item["text"]):
                continue
            marker_box = item.get("bbox")
            if not marker_box:
                continue
            for neighbor_index in (index - 1, index + 1):
                if 0 <= neighbor_index < len(result):
                    neighbor = result[neighbor_index]
                    box = neighbor.get("bbox")
                    if (neighbor["kind"] == "paragraph" and box
                            and abs(box[0] - marker_box[0]) <= 0.02
                            and abs(box[1] - marker_box[1]) <= 0.04):
                        neighbor["kind"] = "list"
        return result
    return [{"id": "0", "kind": "paragraph", "text": "\n\n".join(
        str(item.get("block_content", "")).strip() for item in raw_blocks
        if str(item.get("block_content", "")).strip()), "bbox": None}]


def vl_blocks(payload, width, height):
    raw_blocks = payload.get("parsing_res_list", []) or []
    blocks = []
    for index, block in enumerate(raw_blocks):
        text = str(block.get("block_content", "")).strip()
        if text:
            kind = clean_kind(block.get("block_label"))
            if kind == "paragraph" and re.search(r"(?m)^\s*(?:[—–−-]|[•●▪])\s*", text):
                kind = "list"
            blocks.append({"id": str(index), "kind": kind,
                           "text": text, "bbox": normalized_bbox(block.get("block_bbox"), width, height)})
    if not blocks:
        markdown = payload.get("markdown", {}) or {}
        text = str(markdown.get("text", "")).strip()
        if text:
            blocks = [{"id": "0", "kind": "paragraph", "text": text, "bbox": None}]
    return blocks


def image_dimensions(path):
    from PIL import Image
    with Image.open(path) as image:
        return image.width, image.height


def enhance_image(source, destination):
    """Mild local illumination/contrast normalization without changing geometry."""
    try:
        import cv2
        import numpy as np
        image = cv2.imread(str(source), cv2.IMREAD_COLOR)
        if image is None:
            return str(source)
        lab = cv2.cvtColor(image, cv2.COLOR_BGR2LAB)
        lightness, a, b = cv2.split(lab)
        normalized = cv2.createCLAHE(clipLimit=1.6, tileGridSize=(8, 8)).apply(lightness)
        output = cv2.cvtColor(cv2.merge((normalized, a, b)), cv2.COLOR_LAB2BGR)
        if cv2.imwrite(str(destination), output):
            return str(destination)
    except Exception:
        pass
    return str(source)


def make_pipeline(mode):
    local_models = {
        "layout": local_model("PP-DocLayoutV3", ["inference.yml", "inference.pdiparams"]),
        "orientation": local_model("PP-LCNet_x1_0_doc_ori", ["inference.yml", "inference.pdiparams"]),
        "unwarp": local_model("UVDoc", ["inference.yml", "inference.pdiparams"]),
    }
    if mode == "vl":
        from paddleocr import PaddleOCRVL
        vl = local_model("PaddleOCR-VL-1.6", ["config.json", "model.safetensors", "tokenizer.json"])
        options = dict(
            pipeline_version="v1.6", layout_detection_model_name="PP-DocLayoutV3",
            vl_rec_model_name="PaddleOCR-VL-1.6-0.9B",
            doc_orientation_classify_model_name="PP-LCNet_x1_0_doc_ori",
            doc_unwarping_model_name="UVDoc", use_doc_orientation_classify=True,
            use_doc_unwarping=True, device="cpu",
        )
        if local_models["layout"]:
            options["layout_detection_model_dir"] = str(local_models["layout"])
        if vl:
            options["vl_rec_model_dir"] = str(vl)
        if local_models["orientation"]:
            options["doc_orientation_classify_model_dir"] = str(local_models["orientation"])
        if local_models["unwarp"]:
            options["doc_unwarping_model_dir"] = str(local_models["unwarp"])
        pipeline = PaddleOCRVL(**options)
        return pipeline, None
    det = local_model("PP-OCRv5_mobile_det", ["inference.yml", "inference.pdiparams"])
    printed = local_model("eslav_PP-OCRv5_mobile_rec", ["inference.yml", "inference.pdiparams"])
    from paddleocr import PPStructureV3
    options = dict(
        layout_detection_model_name="PP-DocLayoutV3",
        text_detection_model_name="PP-OCRv5_mobile_det",
        text_recognition_model_name="eslav_PP-OCRv5_mobile_rec",
        doc_orientation_classify_model_name="PP-LCNet_x1_0_doc_ori",
        doc_unwarping_model_name="UVDoc",
        use_doc_orientation_classify=True, use_doc_unwarping=True,
        use_table_recognition=False, use_formula_recognition=False,
        use_chart_recognition=False, use_seal_recognition=False,
        use_region_detection=False,
        use_textline_orientation=False, format_block_content=True, device="cpu",
    )
    optional_dirs = {
        "layout_detection_model_dir": local_models["layout"],
        "text_detection_model_dir": det,
        "text_recognition_model_dir": printed,
        "doc_orientation_classify_model_dir": local_models["orientation"],
        "doc_unwarping_model_dir": local_models["unwarp"],
    }
    options.update({key: str(value) for key, value in optional_dirs.items() if value})
    pipeline = PPStructureV3(**options)
    htr = None
    if mode == "hybrid":
        hand = ensure_cyrillic_model()
        from paddleocr import TextRecognition
        htr = TextRecognition(model_name="PP-OCRv6_medium_rec", model_dir=str(hand),
                              engine="onnxruntime", device="cpu")
    return pipeline, htr


def main():
    request = json.load(sys.stdin)
    items = request.get("items", [])
    mode = request.get("mode", "structure")
    preview_dir = Path(request.get("preview_dir", "")) if request.get("preview_dir") else None
    if preview_dir:
        preview_dir.mkdir(parents=True, exist_ok=True)
    if mode not in {"vl", "structure", "hybrid"}:
        emit({"event": "error", "message": "Неизвестный режим форматирования."})
        return 2
    try:
        emit({"event": "status", "stage": "models", "message": "Проверяю модели и загружаю недостающие…"})
        pipeline, handwritten_recognizer = make_pipeline(mode)
        emit({"event": "status", "stage": "recognition", "message": "Модели готовы · распознаю страницы…"})
        with tempfile.TemporaryDirectory(prefix="lectureocr-enhanced-") as enhanced_dir:
            for index, item in enumerate(items, 1):
                path = item["path"]
                try:
                    width, height = image_dimensions(path)
                    ocr_path = enhance_image(path, Path(enhanced_dir) / f"page-{index}.png")
                    preview_path = None
                    if mode == "vl":
                        predictions = pipeline.predict(ocr_path, use_doc_orientation_classify=True,
                                                       use_doc_unwarping=True, use_chart_recognition=False,
                                                       use_seal_recognition=False)
                        prediction = predictions[0] if predictions else None
                        payload = unpack(prediction) if prediction else {}
                        blocks = None
                    else:
                        predictions = pipeline.predict(ocr_path)
                        prediction = predictions[0] if predictions else None
                        payload = unpack(prediction) if prediction else {}
                        blocks = None
                    processed_image = document_output_image(prediction) if prediction else None
                    if processed_image is not None and getattr(processed_image, "ndim", 0) >= 2:
                        height, width = processed_image.shape[:2]
                        if preview_dir:
                            import cv2
                            candidate_path = preview_dir / f"{item.get('id', index)}.png"
                            if cv2.imwrite(str(candidate_path), processed_image):
                                preview_path = str(candidate_path)
                        if mode != "vl":
                            os.environ["LECTURE_OCR_CURRENT_IMAGE"] = preview_path or ocr_path
                    elif mode != "vl":
                        os.environ["LECTURE_OCR_CURRENT_IMAGE"] = ocr_path
                    if mode != "vl":
                        blocks = structure_blocks(payload, width, height,
                                                  handwritten_recognizer if mode == "hybrid" else None)
                    else:
                        blocks = vl_blocks(payload, width, height)
                    emit({"event": "page", "id": item.get("id", str(index - 1)),
                          "done": index, "total": len(items), "width": width, "height": height,
                          "blocks": blocks, "preview_path": preview_path})
                except Exception as exc:
                    emit({"event": "error", "message": f"Страница {index}: {exc}"})
                    return 1
        return 0
    except Exception as exc:
        message = f"Не удалось подготовить модели или запустить распознавание: {exc}"
        if isinstance(exc, (OSError, urllib.error.URLError)):
            message += "\nПроверьте подключение к интернету и повторите попытку. Уже загруженные модели сохраняются."
        emit({"event": "error", "message": message})
        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
