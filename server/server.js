const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const cors = require('cors');
const { v4: uuidv4 } = require('uuid');

const app = express();
const port = process.env.PORT || 3001;

app.use(cors());
app.use(express.json());

const db = new sqlite3.Database('cardcode.db', (err) => {
  if (err) {
    console.error('数据库连接失败:', err.message);
  } else {
    console.log('数据库连接成功');
    initDatabase();
  }
});

function initDatabase() {
  db.run(`
    CREATE TABLE IF NOT EXISTS card_codes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      code TEXT UNIQUE NOT NULL,
      remaining_count INTEGER DEFAULT 10,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      status TEXT DEFAULT 'active'
    )
  `, (err) => {
    if (err) {
      console.error('创建表失败:', err.message);
    }
  });

  db.run(`
    CREATE TABLE IF NOT EXISTS announcements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at TEXT NOT NULL,
      active INTEGER DEFAULT 1
    )
  `, (err) => {
    if (err) {
      console.error('创建公告表失败:', err.message);
    }
  });

  db.run(`
    CREATE TABLE IF NOT EXISTS user_announcements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL,
      announcement_id INTEGER NOT NULL,
      read_at TEXT
    )
  `, (err) => {
    if (err) {
      console.error('创建用户公告表失败:', err.message);
    }
  });
}

app.get('/', (req, res) => {
  res.send('卡密管理后台 API 服务器');
});

app.post('/cardcode/validate', (req, res) => {
  const { code } = req.body;
  
  if (!code) {
    return res.json({ success: false, message: '请输入卡密' });
  }
  
  db.get('SELECT * FROM card_codes WHERE code = ? AND status = ?', [code, 'active'], (err, row) => {
    if (err) {
      return res.json({ success: false, message: '数据库查询失败' });
    }
    
    if (!row) {
      return res.json({ success: false, message: '卡密不存在或已失效' });
    }
    
    const now = new Date().toISOString();
    if (row.expires_at < now) {
      db.run('UPDATE card_codes SET status = ? WHERE code = ?', ['expired', code]);
      return res.json({ success: false, message: '卡密已过期' });
    }
    
    res.json({
      success: true,
      data: {
        code: row.code,
        expiresAt: row.expires_at,
        remainingCount: row.remaining_count,
        createdAt: row.created_at
      }
    });
  });
});

app.post('/cardcode/deduct', (req, res) => {
  const { code } = req.body;
  
  if (!code) {
    return res.json({ success: false, message: '请输入卡密' });
  }
  
  db.get('SELECT * FROM card_codes WHERE code = ? AND status = ?', [code, 'active'], (err, row) => {
    if (err) {
      return res.json({ success: false, message: '数据库查询失败' });
    }
    
    if (!row) {
      return res.json({ success: false, message: '卡密不存在或已失效' });
    }
    
    const now = new Date().toISOString();
    if (row.expires_at < now) {
      db.run('UPDATE card_codes SET status = ? WHERE code = ?', ['expired', code]);
      return res.json({ success: false, message: '卡密已过期' });
    }
    
    if (row.remaining_count <= 0) {
      db.run('UPDATE card_codes SET status = ? WHERE code = ?', ['used', code]);
      return res.json({ success: false, message: '卡密剩余次数不足' });
    }
    
    const newCount = row.remaining_count - 1;
    
    db.run('UPDATE card_codes SET remaining_count = ? WHERE code = ?', [newCount, code], (err) => {
      if (err) {
        return res.json({ success: false, message: '更新失败' });
      }
      
      if (newCount <= 0) {
        db.run('UPDATE card_codes SET status = ? WHERE code = ?', ['used', code]);
      }
      
      res.json({
        success: true,
        remainingCount: newCount
      });
    });
  });
});

app.post('/cardcode/generate', (req, res) => {
  const { count = 1, days = 30, initialCount = 10 } = req.body;
  
  const codes = [];
  const now = new Date();
  
  for (let i = 0; i < count; i++) {
    const code = uuidv4().toUpperCase().replace(/-/g, '').substring(0, 16);
    const expiresAt = new Date(now.getTime() + days * 24 * 60 * 60 * 1000).toISOString();
    const createdAt = now.toISOString();
    
    codes.push({
      code,
      expires_at: expiresAt,
      created_at: createdAt,
      remaining_count: initialCount
    });
  }
  
  const placeholders = codes.map(() => '(?, ?, ?, ?)').join(',');
  const values = codes.flatMap(c => [c.code, c.remaining_count, c.expires_at, c.created_at]);
  
  db.run(`INSERT INTO card_codes (code, remaining_count, expires_at, created_at) VALUES ${placeholders}`, values, (err) => {
    if (err) {
      return res.json({ success: false, message: '生成卡密失败: ' + err.message });
    }
    
    res.json({
      success: true,
      count: codes.length,
      codes: codes.map(c => ({ code: c.code, expiresAt: c.expires_at, remainingCount: c.remaining_count }))
    });
  });
});

app.get('/cardcode/list', (req, res) => {
  const { page = 1, limit = 20, status } = req.query;
  const offset = (page - 1) * limit;
  
  let query = 'SELECT * FROM card_codes';
  let params = [];
  
  if (status) {
    query += ' WHERE status = ?';
    params.push(status);
  }
  
  query += ' ORDER BY created_at DESC LIMIT ? OFFSET ?';
  params.push(parseInt(limit), parseInt(offset));
  
  db.all(query, params, (err, rows) => {
    if (err) {
      return res.json({ success: false, message: '查询失败' });
    }
    
    db.get('SELECT COUNT(*) as total FROM card_codes' + (status ? ' WHERE status = ?' : ''), status ? [status] : [], (err, countRow) => {
      res.json({
        success: true,
        data: rows.map(row => ({
          id: row.id,
          code: row.code,
          remainingCount: row.remaining_count,
          expiresAt: row.expires_at,
          createdAt: row.created_at,
          status: row.status
        })),
        total: countRow?.total || 0,
        page: parseInt(page),
        limit: parseInt(limit)
      });
    });
  });
});

app.get('/cardcode/:code', (req, res) => {
  const { code } = req.params;
  
  db.get('SELECT * FROM card_codes WHERE code = ?', [code], (err, row) => {
    if (err) {
      return res.json({ success: false, message: '查询失败' });
    }
    
    if (!row) {
      return res.json({ success: false, message: '卡密不存在' });
    }
    
    res.json({
      success: true,
      data: {
        id: row.id,
        code: row.code,
        remainingCount: row.remaining_count,
        expiresAt: row.expires_at,
        createdAt: row.created_at,
        status: row.status
      }
    });
  });
});

app.delete('/cardcode/:id', (req, res) => {
  const { id } = req.params;
  
  db.run('DELETE FROM card_codes WHERE id = ?', [id], (err) => {
    if (err) {
      return res.json({ success: false, message: '删除失败' });
    }
    
    res.json({ success: true, message: '删除成功' });
  });
});

app.post('/cardcode/update/:id', (req, res) => {
  const { id } = req.params;
  const { remainingCount, expiresAt, status } = req.body;
  
  let updates = [];
  let params = [];
  
  if (remainingCount !== undefined) {
    updates.push('remaining_count = ?');
    params.push(remainingCount);
  }
  if (expiresAt) {
    updates.push('expires_at = ?');
    params.push(expiresAt);
  }
  if (status) {
    updates.push('status = ?');
    params.push(status);
  }
  
  if (updates.length === 0) {
    return res.json({ success: false, message: '没有需要更新的字段' });
  }
  
  params.push(id);
  
  db.run(`UPDATE card_codes SET ${updates.join(', ')} WHERE id = ?`, params, (err) => {
    if (err) {
      return res.json({ success: false, message: '更新失败' });
    }
    
    res.json({ success: true, message: '更新成功' });
  });
});

// 公告管理 API

app.post('/announcement/create', (req, res) => {
  const { title, content } = req.body;
  
  if (!title || !content) {
    return res.json({ success: false, message: '请填写标题和内容' });
  }
  
  const createdAt = new Date().toISOString();
  
  db.run('INSERT INTO announcements (title, content, created_at) VALUES (?, ?, ?)', [title, content, createdAt], (err) => {
    if (err) {
      return res.json({ success: false, message: '创建失败: ' + err.message });
    }
    
    res.json({
      success: true,
      message: '公告发布成功',
      data: { id: this.lastID, title, content, createdAt }
    });
  });
});

app.get('/announcement/list', (req, res) => {
  const { page = 1, limit = 20 } = req.query;
  const offset = (page - 1) * limit;
  
  db.all('SELECT * FROM announcements ORDER BY created_at DESC LIMIT ? OFFSET ?', [parseInt(limit), parseInt(offset)], (err, rows) => {
    if (err) {
      return res.json({ success: false, message: '查询失败' });
    }
    
    db.get('SELECT COUNT(*) as total FROM announcements', (err, countRow) => {
      res.json({
        success: true,
        data: rows.map(row => ({
          id: row.id,
          title: row.title,
          content: row.content,
          createdAt: row.created_at,
          active: row.active === 1
        })),
        total: countRow?.total || 0,
        page: parseInt(page),
        limit: parseInt(limit)
      });
    });
  });
});

app.get('/announcement/:id', (req, res) => {
  const { id } = req.params;
  
  db.get('SELECT * FROM announcements WHERE id = ?', [id], (err, row) => {
    if (err) {
      return res.json({ success: false, message: '查询失败' });
    }
    
    if (!row) {
      return res.json({ success: false, message: '公告不存在' });
    }
    
    res.json({
      success: true,
      data: {
        id: row.id,
        title: row.title,
        content: row.content,
        createdAt: row.created_at,
        active: row.active === 1
      }
    });
  });
});

app.post('/announcement/update/:id', (req, res) => {
  const { id } = req.params;
  const { title, content, active } = req.body;
  
  let updates = [];
  let params = [];
  
  if (title) {
    updates.push('title = ?');
    params.push(title);
  }
  if (content) {
    updates.push('content = ?');
    params.push(content);
  }
  if (active !== undefined) {
    updates.push('active = ?');
    params.push(active ? 1 : 0);
  }
  
  if (updates.length === 0) {
    return res.json({ success: false, message: '没有需要更新的字段' });
  }
  
  params.push(id);
  
  db.run(`UPDATE announcements SET ${updates.join(', ')} WHERE id = ?`, params, (err) => {
    if (err) {
      return res.json({ success: false, message: '更新失败' });
    }
    
    res.json({ success: true, message: '更新成功' });
  });
});

app.delete('/announcement/:id', (req, res) => {
  const { id } = req.params;
  
  db.run('DELETE FROM announcements WHERE id = ?', [id], (err) => {
    if (err) {
      return res.json({ success: false, message: '删除失败' });
    }
    
    res.json({ success: true, message: '删除成功' });
  });
});

// 用户获取未读公告
app.post('/announcement/unread', (req, res) => {
  const { userId } = req.body;
  
  if (!userId) {
    return res.json({ success: false, message: '用户ID不能为空' });
  }
  
  db.all(`
    SELECT a.* 
    FROM announcements a
    LEFT JOIN user_announcements ua ON a.id = ua.announcement_id AND ua.user_id = ?
    WHERE ua.id IS NULL AND a.active = 1
    ORDER BY a.created_at DESC
  `, [userId], (err, rows) => {
    if (err) {
      return res.json({ success: false, message: '查询失败' });
    }
    
    res.json({
      success: true,
      data: rows.map(row => ({
        id: row.id,
        title: row.title,
        content: row.content,
        createdAt: row.created_at
      }))
    });
  });
});

// 标记公告为已读
app.post('/announcement/mark-read', (req, res) => {
  const { userId, announcementId } = req.body;
  
  if (!userId || !announcementId) {
    return res.json({ success: false, message: '参数不完整' });
  }
  
  db.get('SELECT * FROM user_announcements WHERE user_id = ? AND announcement_id = ?', [userId, announcementId], (err, row) => {
    if (err) {
      return res.json({ success: false, message: '查询失败' });
    }
    
    if (row) {
      return res.json({ success: true, message: '已标记为已读' });
    }
    
    const readAt = new Date().toISOString();
    
    db.run('INSERT INTO user_announcements (user_id, announcement_id, read_at) VALUES (?, ?, ?)', [userId, announcementId, readAt], (err) => {
      if (err) {
        return res.json({ success: false, message: '标记失败' });
      }
      
      res.json({ success: true, message: '标记成功' });
    });
  });
});

app.listen(port, () => {
  console.log(`服务器运行在 http://localhost:${port}`);
});